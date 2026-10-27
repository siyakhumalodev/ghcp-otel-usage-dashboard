# Portal Setup Guide

This guide walks through creating every resource for the Copilot Usage Dashboard using the **Azure Portal** with minimal CLI usage. CLI snippets are only included where the Portal does not expose a particular option.

The setup mounts `config.yaml` from an Azure Files share into the container, so the public `otel/opentelemetry-collector-contrib` image is used directly — no custom Docker build required.

---

## Resources to Create (in order)

1. Resource group
2. Log Analytics workspace
3. Application Insights (workspace-based)
4. Storage account + file share + upload `config.yaml`
5. Key Vault + connection string secret
6. Container App Environment (with file share registered)
7. Container App (ingress, file share mount, managed identity, Key Vault secret)
8. Azure Managed Grafana

---

## Step 1 — Resource Group

1. In the Azure Portal, search for **Resource groups** and click **+ Create**
2. Fill in:
   - **Subscription** — your subscription
   - **Resource group** — `copilot-dashboard-rg`
   - **Region** — `North Europe` (or your preferred region)
3. Click **Review + create → Create**

---

## Step 2 — Log Analytics Workspace

A Log Analytics workspace is required for workspace-based Application Insights and Container App logging.

1. Search for **Log Analytics workspaces** → **+ Create**
2. Fill in:
   - **Resource group** — `copilot-dashboard-rg`
   - **Name** — `copilot-dash-law`
   - **Region** — same as the resource group
3. Click **Review + create → Create**

---

## Step 3 — Application Insights

1. Search for **Application Insights** → **+ Create**
2. Fill in:
   - **Resource group** — `copilot-dashboard-rg`
   - **Name** — `copilot-dash-ai`
   - **Region** — same as the resource group
   - **Resource Mode** — **Workspace-based** *(required for OTel metrics)*
   - **Log Analytics Workspace** — `copilot-dash-law`
3. Click **Review + create → Create**

### Note the connection string

1. Open the new Application Insights resource
2. On the **Overview** page, copy the **Connection String** — you will store it in Key Vault in Step 5

> OTel metrics and traces arrive as `customMetrics` and `dependencies` in workspace-based Application Insights automatically — no additional toggle is needed.

---

## Step 4 — Storage Account and File Share

### 4.1 Create the storage account

1. Search for **Storage accounts** → **+ Create**
2. Fill in:
   - **Resource group** — `copilot-dashboard-rg`
   - **Storage account name** — `copilotdashotelconfig` *(lowercase, no hyphens)*
   - **Region** — same as the resource group
   - **Performance** — Standard
   - **Redundancy** — LRS
3. Click **Review + create → Create**

### 4.2 Create the file share

1. Open the new storage account
2. In the left menu, go to **Data storage → File shares → + File share**
3. Fill in:
   - **Name** — `otel-config`
   - **Tier** — Transaction optimized
4. Click **Create**

### 4.3 Grant yourself upload permissions

To upload files using your Entra ID identity (rather than a storage key), you need the **Storage File Data Privileged Contributor** role on the storage account.

See: [Authorize data operations in the portal](https://learn.microsoft.com/en-gb/azure/storage/files/authorize-data-operations-portal)

1. Open the storage account → **Access control (IAM) → + Add → Add role assignment**
2. Search for `Storage File Data Privileged Contributor` → select it → **Next**
3. **Members** → **+ Select members** → search for your own name → Select
4. Click **Review + assign → Review + assign**

> Allow ~1 minute for the role assignment to propagate before uploading.

### 4.4 Upload `config.yaml`

**Via the Azure Portal:**

1. Open the storage account → **Data storage → File shares → otel-config**
2. Click the **↑ Upload** button
3. In the upload pane, click the folder icon and select `config.yaml` from this repository
4. Click **Upload**

**Via Azure Storage Explorer (desktop app):**

1. Install [Azure Storage Explorer](https://azure.microsoft.com/en-us/products/storage/storage-explorer/)
2. Sign in with your Azure account
3. Expand **Storage Accounts → copilotdashotelconfig → File Shares → otel-config**
4. Click **Upload → Upload Files**, select `config.yaml`, and confirm

The file will be accessible to the container at `/etc/otelcol-contrib/config.yaml` once the file share is mounted in Step 7.

---

## Step 5 — Key Vault

Storing the Application Insights connection string in Key Vault keeps it out of Container App plain-text environment variables.

### 5.1 Create the Key Vault

1. Search for **Key vaults** → **+ Create**
2. Fill in:
   - **Resource group** — `copilot-dashboard-rg`
   - **Key vault name** — `copilot-dash-kv`
   - **Region** — same as the resource group
   - **Pricing tier** — Standard
3. On the **Access configuration** tab:
   - **Permission model** — **Azure role-based access control**
4. Click **Review + create → Create**

### 5.2 Grant yourself the ability to add secrets

1. Open the Key Vault → **Access control (IAM) → + Add → Add role assignment**
2. Search for `Key Vault Secrets Officer` → select → **Next**
3. Add yourself as the member → **Review + assign**

### 5.3 Add the connection string as a secret

1. Open the Key Vault → **Objects → Secrets → + Generate/Import**
2. Fill in:
   - **Upload options** — Manual
   - **Name** — `AppInsightsConnectionString`
   - **Secret value** — paste the connection string copied in Step 3
3. Click **Create**

### 5.4 Note the secret URI

1. Open the secret → click the current version
2. Copy the **Secret Identifier** URL — you will need it when configuring the Container App secret reference in Step 7

---

## Step 6 — Container App Environment

### 6.1 Create the environment

1. Search for **Container App Environments** → **+ Create**
2. Fill in:
   - **Resource group** — `copilot-dashboard-rg`
   - **Name** — `copilot-dash-cae`
   - **Region** — same as the resource group
3. On the **Monitoring** tab:
   - **Log Analytics workspace** — `copilot-dash-law`
4. Click **Review + create → Create**

### 6.2 Register the file share with the environment

The Container App Environment must know about the storage account before apps can mount it. This step requires the CLI because the Portal does not expose environment-level storage configuration:

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

---

## Step 7 — Container App

### 7.1 Create the Container App

1. Search for **Container Apps** → **+ Create**
2. On the **Basics** tab:
   - **Resource group** — `copilot-dashboard-rg`
   - **Container app name** — `copilot-dash-collector`
   - **Region** — same as the resource group
   - **Container Apps Environment** — `copilot-dash-cae`
3. Click **Next: Container**

### 7.2 Configure the container image

On the **Container** tab:

- **Image source** — Docker Hub or other registries
- **Image and tag** — `otel/opentelemetry-collector-contrib:latest`
- **CPU and Memory** — `0.5 CPU, 1 Gi memory`

Leave environment variables empty for now — the connection string will be added as a secret reference after creation.

Click **Next: Bindings**, then **Next: Ingress**.

### 7.3 Configure ingress

On the **Ingress** tab:

- **Ingress** — **Enabled**
- **Ingress traffic** — **Accepting traffic from anywhere**
- **Ingress type** — **HTTP**
- **Target port** — `4318`

> Port 4318 is the OTLP/HTTP receiver port defined in `config.yaml`. Azure Container Apps terminates TLS externally on port 443 and proxies requests to port 4318 inside the container.

Click **Review + create → Create**.

### 7.4 Enable system-assigned managed identity

1. Open the Container App → **Settings → Identity**
2. On the **System assigned** tab, toggle **Status** to **On**
3. Click **Save** → confirm the prompt

Note the **Object (principal) ID** displayed — you will use it for role assignments.

### 7.5 Grant the Container App access to Key Vault

1. Open **Key Vault `copilot-dash-kv`** → **Access control (IAM) → + Add → Add role assignment**
2. Search for `Key Vault Secrets User` → select → **Next**
3. **Assign access to** — **Managed identity**
4. Click **+ Select members** → set **Managed identity** to **Container App** → select `copilot-dash-collector`
5. Click **Review + assign**

### 7.6 Add the Key Vault secret reference to the Container App

1. Open the Container App → **Settings → Secrets → + Add**
2. Fill in:
   - **Key** — `appinsights-conn-str`
   - **Type** — **Key Vault reference**
   - **Key Vault secret URL** — paste the Secret Identifier URI from Step 5.4 *(use the versionless URI — remove the trailing `/xxxxxxxx...` version segment)*
   - **Managed identity** — **System assigned**
3. Click **Add**

### 7.7 Wire the secret to an environment variable

1. Open the Container App → **Settings → Containers → Edit and deploy**
2. Select the container → **Edit**
3. Under **Environment variables**, click **+ Add**:
   - **Name** — `APPLICATIONINSIGHTS_CONNECTION_STRING`
   - **Source** — **Reference a secret**
   - **Value** — `appinsights-conn-str`
4. Click **Save → Create** to create a new revision

### 7.8 Mount the file share

1. Open the Container App → **Settings → Containers → Edit and deploy**  
   *(or continue from the previous edit if still in the deploy flow)*
2. Go to the **Scale and volumes** tab → **Volumes → + Add volume**:
   - **Volume type** — **Azure file volume**
   - **Name** — `otelconfigvol`
   - **Storage** — `otelconfig` *(registered in Step 6.2)*
3. On the **Container** tab, select the container → **Edit**
4. Under **Volume mounts → + Add volume mount**:
   - **Volume** — `otelconfigvol`
   - **Mount path** — `/etc/otelcol-contrib`
5. Click **Save → Create** to deploy the revision

### 7.9 Verify the container is running

1. Open the Container App → **Monitoring → Log stream**
2. Wait for the revision to start — look for:
   ```
   Everything is ready. Begin running and processing data.
   ```
   This confirms `config.yaml` was loaded from the file share and the connection string secret was resolved.

3. Note the application URL shown on the **Overview** page — this is the `<container_app_fqdn>` used in the VS Code settings.

---

## Step 8 — Configure VS Code

Add the following to each developer's **User Settings** (`settings.json`), replacing `<container_app_fqdn>` with the URL from Step 7.9:

```json
{
  "github.copilot.nextEditSuggestions.enabled": true,
  "github.copilot.chat.otel.enabled": true,
  "github.copilot.chat.otel.exporterType": "otlp-http",
  "github.copilot.chat.otel.otlpEndpoint": "https://<container_app_fqdn>"
}
```

Open the Command Palette → **Preferences: Open User Settings (JSON)**, add the settings, save, and restart VS Code.

---

## Step 9 — Azure Managed Grafana

### 9.1 Create the Managed Grafana instance

1. Search for **Azure Managed Grafana** → **+ Create**
2. Fill in:
   - **Resource group** — `copilot-dashboard-rg`
   - **Name** — `copilot-dash-grafana`
   - **Region** — same as the resource group
   - **Pricing plan** — Standard
3. On the **Advanced** tab:
   - **Enable system-assigned managed identity** — checked
4. Click **Review + create → Create**

### 9.2 Grant Grafana access to Application Insights

1. Open the resource group `copilot-dashboard-rg` → **Access control (IAM) → + Add → Add role assignment**
2. Search for `Monitoring Reader` → select → **Next**
3. **Assign access to** — **Managed identity**
4. Click **+ Select members** → set **Managed identity** to **Azure Managed Grafana** → select `copilot-dash-grafana`
5. Click **Review + assign**

### 9.3 Grant yourself Grafana Admin

1. Open the Managed Grafana resource → **Access control (IAM) → + Add → Add role assignment**
2. Search for `Grafana Admin` → select → **Next**
3. Add yourself as the member → **Review + assign**

### 9.4 Add the Azure Monitor data source

1. Open the Managed Grafana resource → click the **Endpoint** URL to open the Grafana UI
2. In Grafana, go to **Connections → Data sources → Add new data source**
3. Select **Azure Monitor**
4. Set **Authentication** to **Managed Identity**
5. Set **Default subscription** to your Azure subscription
6. Click **Save & Test** — should report a successful connection

### 9.5 Import the dashboard

1. In Grafana, go to **Dashboards → Import**
2. Click **Upload dashboard JSON file**
3. Select `grafana-agent-usage-geo.json` from this repository
4. On the next screen, map the `DS_AZURE_MONITOR` input to the Azure Monitor data source
5. Click **Import**

---

## Step 10 — Verification

| Check | Where to look |
|---|---|
| Config loaded by collector | Container App → **Monitoring → Log stream** — look for `"Everything is ready"` |
| Telemetry arriving at collector | Log stream — look for `POST /v1/traces` or `POST /v1/metrics` after using Copilot in VS Code |
| Data in Application Insights | Application Insights → **Transaction Search** → filter type: `Dependency` |
| Grafana panels populated | Open the imported dashboard — panels show data after a few minutes of Copilot activity |

---

## Updating `config.yaml`

Because the config is stored in the file share, updates require no image rebuild:

1. Edit `config.yaml` locally
2. Re-upload it using the Portal or Storage Explorer (Step 4.4)
3. Open the Container App → **Revisions → Create new revision** to restart and pick up the new file

---

## Tear Down

1. Open the Azure Portal → **Resource groups**
2. Select `copilot-dashboard-rg`
3. Click **Delete resource group**, type the name to confirm, and click **Delete**
