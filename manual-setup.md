# Manual Setup Guide

This guide covers building and configuring the Copilot Usage Dashboard entirely through the Azure Portal and CLI, without Terraform. It is an alternative to the automated approach in [plan.md](plan.md).

The manual approach uses an **Azure Storage file share** to mount `config.yaml` into the container at runtime, so the base `otel/opentelemetry-collector-contrib` image can be used directly without building a custom Docker image.

---

## Overview of Resources to Create

1. Resource group
2. Log Analytics workspace
3. Application Insights (workspace-based, OTel metrics enabled)
4. Storage account + file share (for `config.yaml` mount)
5. Key Vault (for Application Insights connection string)
6. Container App Environment
7. Container App (with ingress, file share mount, managed identity)
8. Azure Managed Grafana

---

## Step 1 — Resource Group

```bash
az group create --name copilot-dashboard-rg --location northeurope
```

---

## Step 2 — Application Insights (with OTel Metrics)

Workspace-based Application Insights is required for OTel metrics ingestion.

### 2.1 Create a Log Analytics workspace

```bash
az monitor log-analytics workspace create \
  --resource-group copilot-dashboard-rg \
  --workspace-name copilot-dash-law \
  --location northeurope
```

### 2.2 Create Application Insights

```bash
LAW_ID=$(az monitor log-analytics workspace show \
  --resource-group copilot-dashboard-rg \
  --workspace-name copilot-dash-law \
  --query id -o tsv)

az monitor app-insights component create \
  --app copilot-dash-ai \
  --location northeurope \
  --resource-group copilot-dashboard-rg \
  --workspace "${LAW_ID}" \
  --application-type web
```

### 2.3 Enable OTel metrics ingestion

In the Azure Portal:

1. Open the Application Insights resource → **Settings → Properties**
2. Confirm **Workspace-based** is shown — this is required for OTel metrics
3. Navigate to **Configure → Metrics** — custom OTel metrics arrive as `customMetrics` and are available automatically; no additional toggle is needed for workspace-based instances

### 2.4 Note the connection string

```bash
az monitor app-insights component show \
  --app copilot-dash-ai \
  --resource-group copilot-dashboard-rg \
  --query connectionString -o tsv
```

Save this value — you will store it in Key Vault in Step 4.

---

## Step 3 — Storage Account and File Share

The OTel Collector contrib image reads its configuration from `/etc/otelcol-contrib/config.yaml`. Rather than baking the file into a custom Docker image, mount an Azure Files share at `/etc/otelcol-contrib/` so the config can be updated without rebuilding the image.

### 3.1 Create the storage account

```bash
az storage account create \
  --name copilotdashotelconfig \
  --resource-group copilot-dashboard-rg \
  --location northeurope \
  --sku Standard_LRS \
  --kind StorageV2 \
  --enable-large-file-share false
```

### 3.2 Create the file share

```bash
az storage share create \
  --name otel-config \
  --account-name copilotdashotelconfig
```

### 3.3 Assign yourself the upload role

To upload files through the Azure Portal or Storage Explorer using your Entra ID identity (rather than a storage key), you need the **Storage File Data Privileged Contributor** role.

See: [Authorize data operations in the portal](https://learn.microsoft.com/en-gb/azure/storage/files/authorize-data-operations-portal)

```bash
STORAGE_ID=$(az storage account show \
  --name copilotdashotelconfig \
  --resource-group copilot-dashboard-rg \
  --query id -o tsv)

USER_OID=$(az ad signed-in-user show --query id -o tsv)

az role assignment create \
  --role "Storage File Data Privileged Contributor" \
  --assignee "${USER_OID}" \
  --scope "${STORAGE_ID}"
```

### 3.4 Upload `config.yaml`

**Option A — Azure Portal:**

1. Open the storage account → **Data storage → File shares → otel-config**
2. Click **Upload**
3. Select `config.yaml` from this repository
4. Click **Upload**

**Option B — Azure Storage Explorer (desktop app):**

1. Install [Azure Storage Explorer](https://azure.microsoft.com/en-us/products/storage/storage-explorer/)
2. Sign in with your Azure account
3. Expand your subscription → Storage Accounts → **copilotdashotelconfig** → File Shares → **otel-config**
4. Click **Upload → Upload Files**, select `config.yaml`, and confirm

**Option C — Azure CLI:**

```bash
az storage file upload \
  --account-name copilotdashotelconfig \
  --share-name otel-config \
  --source config.yaml \
  --auth-mode login
```

After uploading, `config.yaml` sits at the root of the file share. The Container App will mount the share at `/etc/otelcol-contrib/`, making it accessible to the collector at `/etc/otelcol-contrib/config.yaml`.

---

## Step 4 — Key Vault for the Connection String

Storing the Application Insights connection string in Key Vault keeps it out of Container App environment variable plain text and enables rotation without redeploying.

### 4.1 Create the Key Vault

```bash
az keyvault create \
  --name copilot-dash-kv \
  --resource-group copilot-dashboard-rg \
  --location northeurope \
  --enable-rbac-authorization true
```

### 4.2 Store the connection string

```bash
CONN_STR=$(az monitor app-insights component show \
  --app copilot-dash-ai \
  --resource-group copilot-dashboard-rg \
  --query connectionString -o tsv)

az keyvault secret set \
  --vault-name copilot-dash-kv \
  --name AppInsightsConnectionString \
  --value "${CONN_STR}"
```

The Container App will be granted read access to this secret via its managed identity in Step 6.

---

## Step 5 — Container App Environment

```bash
az containerapp env create \
  --name copilot-dash-cae \
  --resource-group copilot-dashboard-rg \
  --location northeurope \
  --logs-workspace-id $(az monitor log-analytics workspace show \
      --resource-group copilot-dashboard-rg \
      --workspace-name copilot-dash-law \
      --query customerId -o tsv)
```

### 5.1 Register the file share with the environment

The environment must know about the storage account before Container Apps can mount it.

```bash
STORAGE_KEY=$(az storage account keys list \
  --account-name copilotdashotelconfig \
  --resource-group copilot-dashboard-rg \
  --query "[0].value" -o tsv)

az containerapp env storage set \
  --name copilot-dash-cae \
  --resource-group copilot-dashboard-rg \
  --storage-name otelconfig \
  --azure-file-account-name copilotdashotelconfig \
  --azure-file-account-key "${STORAGE_KEY}" \
  --azure-file-share-name otel-config \
  --access-mode ReadOnly
```

> **Note:** The `--azure-file-account-key` used here is for the environment-level storage registration only. The Container App itself will use its managed identity for all other Azure resource access.

---

## Step 6 — Container App

### 6.1 Create the Container App with file share mount and ingress

This uses the public `otel/opentelemetry-collector-contrib` image directly — no custom build required, because the config is mounted from the file share.

```bash
az containerapp create \
  --name copilot-dash-collector \
  --resource-group copilot-dashboard-rg \
  --environment copilot-dash-cae \
  --image otel/opentelemetry-collector-contrib:latest \
  --cpu 0.5 \
  --memory 1Gi \
  --min-replicas 1 \
  --max-replicas 1 \
  --ingress external \
  --target-port 4318 \
  --transport http \
  --system-assigned \
  --volume-mount "otelconfigvol:/etc/otelcol-contrib" \
  --volumes "name=otelconfigvol,storageType=AzureFile,storageName=otelconfig"
```

> **Ingress explained:** Azure Container Apps terminates TLS on port **443** and proxies to the container on `target-port 4318`. VS Code connects to `https://<fqdn>` (no port suffix needed).

### 6.2 Identity and Key Vault access

The Container App was created with `--system-assigned` above. Grant its identity the **Key Vault Secrets User** role so it can read the connection string at startup:

```bash
CA_PRINCIPAL=$(az containerapp show \
  --name copilot-dash-collector \
  --resource-group copilot-dashboard-rg \
  --query identity.principalId -o tsv)

KV_ID=$(az keyvault show \
  --name copilot-dash-kv \
  --resource-group copilot-dashboard-rg \
  --query id -o tsv)

az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee "${CA_PRINCIPAL}" \
  --scope "${KV_ID}"
```

### 6.3 Wire the Key Vault secret to the environment variable

Container Apps supports Key Vault secret references natively. The secret value is injected as an environment variable at container startup and refreshed automatically when the secret is rotated.

First, get the secret URI:

```bash
SECRET_URI=$(az keyvault secret show \
  --vault-name copilot-dash-kv \
  --name AppInsightsConnectionString \
  --query id -o tsv | sed 's|/[^/]*$||')
# strips the version suffix to get a versionless reference
```

Then update the Container App to reference it:

```bash
az containerapp secret set \
  --name copilot-dash-collector \
  --resource-group copilot-dashboard-rg \
  --secrets "appinsights-conn-str=keyvaultref:${SECRET_URI},identityref:system"

az containerapp update \
  --name copilot-dash-collector \
  --resource-group copilot-dashboard-rg \
  --set-env-vars "APPLICATIONINSIGHTS_CONNECTION_STRING=secretref:appinsights-conn-str"
```

### 6.4 Identity for the file share

The file share is registered at the environment level using a storage key (Step 5.1). If you want to eliminate the storage key entirely, assign the Container App's managed identity the **Storage File Data SMB Share Reader** role on the storage account and use identity-based access:

```bash
STORAGE_ID=$(az storage account show \
  --name copilotdashotelconfig \
  --resource-group copilot-dashboard-rg \
  --query id -o tsv)

az role assignment create \
  --role "Storage File Data SMB Share Reader" \
  --assignee "${CA_PRINCIPAL}" \
  --scope "${STORAGE_ID}"
```

> Currently, environment-level storage registration in Container Apps requires a storage key. The managed identity assignment above is supplementary — it ensures the container process itself can also authenticate to the share if the OTel Collector ever performs direct SDK-level file access.

### 6.5 Verify the mount and get the public FQDN

```bash
# Check the container app is running
az containerapp show \
  --name copilot-dash-collector \
  --resource-group copilot-dashboard-rg \
  --query "properties.latestRevisionFqdn" -o tsv

# Stream logs to confirm config.yaml is loaded
az containerapp logs show \
  --name copilot-dash-collector \
  --resource-group copilot-dashboard-rg \
  --follow
```

Look for `"Everything is ready. Begin running and processing data."` in the log output to confirm the collector loaded `config.yaml` successfully.

---

## Step 7 — Azure Managed Grafana

### 7.1 Create the Managed Grafana instance

```bash
az grafana create \
  --name copilot-dash-grafana \
  --resource-group copilot-dashboard-rg \
  --location northeurope \
  --sku Standard
```

### 7.2 Grant Grafana access to Application Insights

```bash
GRAFANA_PRINCIPAL=$(az grafana show \
  --name copilot-dash-grafana \
  --resource-group copilot-dashboard-rg \
  --query identity.principalId -o tsv)

RG_ID=$(az group show --name copilot-dashboard-rg --query id -o tsv)

az role assignment create \
  --role "Monitoring Reader" \
  --assignee "${GRAFANA_PRINCIPAL}" \
  --scope "${RG_ID}"
```

### 7.3 Grant yourself Grafana Admin

```bash
USER_OID=$(az ad signed-in-user show --query id -o tsv)
GRAFANA_ID=$(az grafana show \
  --name copilot-dash-grafana \
  --resource-group copilot-dashboard-rg \
  --query id -o tsv)

az role assignment create \
  --role "Grafana Admin" \
  --assignee "${USER_OID}" \
  --scope "${GRAFANA_ID}"
```

### 7.4 Add the Azure Monitor data source

In the Azure Portal, open the Managed Grafana resource and click **Visit** to open the Grafana UI, then:

1. Go to **Connections → Data sources → Add new data source**
2. Select **Azure Monitor**
3. Set **Authentication** to **Managed Identity**
4. Set **Default subscription** to your Azure subscription
5. Click **Save & Test** — should report success

### 7.5 Import the dashboard

The Grafana dashboard is imported via **Dashboards with Grafana** — this is the standard Grafana dashboard import, available through the Managed Grafana instance linked to Application Insights.

1. In Grafana, go to **Dashboards → Import**
2. Click **Upload dashboard JSON file**
3. Select `grafana-agent-usage-geo.json` from this repository
4. Map the `DS_AZURE_MONITOR` input to the Azure Monitor data source created above
5. Click **Import**

Alternatively, import via the CLI:

```bash
az grafana dashboard import \
  --name copilot-dash-grafana \
  --resource-group copilot-dashboard-rg \
  --definition @grafana-agent-usage-geo.json
```

### 7.6 Dashboard Security and End-User Authentication

Azure Managed Grafana integrates with Azure Active Directory (Azure AD) for authentication and authorization, controlling which users can view dashboards and whether they can edit them.

#### Authentication

When users access the Grafana instance, they authenticate via Azure AD:

1. In Grafana, go to **Administration → Settings → Authentication**
2. Azure AD is the default authentication provider for Managed Grafana
3. Users must be members of the Azure subscription or have explicit Azure AD access to the Managed Grafana resource
4. Access is controlled via Azure RBAC roles assigned at the Managed Grafana resource scope

#### Role-Based Access Control (RBAC)

Managed Grafana supports the following built-in Azure roles:

- **Grafana Admin** — Full access; can create, edit, and delete dashboards and data sources
- **Grafana Editor** — Can create and edit dashboards; cannot modify data sources
- **Grafana Viewer** — Read-only access; can view dashboards but cannot edit them

#### Restrict Users to View-Only

To ensure end users cannot modify dashboards:

1. Assign these users the **Grafana Viewer** role only:

```bash
az role assignment create \
  --role "Grafana Viewer" \
  --assignee "<user_object_id>" \
  --scope "${GRAFANA_ID}"
```

2. Alternatively, remove **Grafana Editor** and **Grafana Admin** roles and keep only **Grafana Viewer**:

```bash
az role assignment delete \
  --role "Grafana Editor" \
  --assignee "<user_object_id>" \
  --scope "${GRAFANA_ID}"
```

With the **Grafana Viewer** role, users can only:
- View dashboards
- View panels and charts
- Use dashboard variables and filters

Users **cannot**:
- Create or edit dashboards
- Modify data sources
- Change settings or provisioning
- Access the administration panel

#### Assign Roles

To grant a user access to Grafana with a specific role:

```bash
USER_OID=$(az ad user show --upn <user_email> --query id -o tsv)

az role assignment create \
  --role "Grafana Viewer" \
  --assignee "${USER_OID}" \
  --scope "${GRAFANA_ID}"
```

---

## Step 8 — Configure VS Code

Add the following to each developer's VS Code **User Settings** (`settings.json`), using the Container App FQDN from Step 6.5:

```json
{
  "github.copilot.nextEditSuggestions.enabled": true,
  "github.copilot.chat.otel.enabled": true,
  "github.copilot.chat.otel.exporterType": "otlp-http",
  "github.copilot.chat.otel.otlpEndpoint": "https://<container_app_fqdn>"
}
```

Restart VS Code. Use Copilot Chat to trigger telemetry, then verify data in Application Insights as described in the Troubleshooting section of [README.md](README.md).

---

## Updating `config.yaml`

Because the config is stored in the file share rather than baked into an image, updates are immediate:

1. Edit `config.yaml` locally
2. Re-upload it using any method from Step 3.4
3. Restart the Container App revision to pick up the new file:

```bash
az containerapp revision restart \
  --name copilot-dash-collector \
  --resource-group copilot-dashboard-rg \
  --revision $(az containerapp revision list \
      --name copilot-dash-collector \
      --resource-group copilot-dashboard-rg \
      --query "[0].name" -o tsv)
```

---

## Tear Down

```bash
az group delete --name copilot-dashboard-rg --yes
```
