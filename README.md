---
title: GitHub Copilot Usage Dashboard
description: Deploy and operate a GitHub Copilot telemetry dashboard on Azure using OpenTelemetry, Application Insights, and Azure Managed Grafana
ms.date: 2026-10-28
ms.topic: overview
---

GitHub Copilot Usage Dashboard collects OpenTelemetry emitted by GitHub Copilot
Chat in VS Code and visualizes agent activity, model usage, token consumption,
response duration, tool calls, and user location in Azure Managed Grafana.

![GitHub Copilot usage dashboard](sample-dashboard.png)

> [!IMPORTANT]
> The collector has public HTTPS ingress so VS Code clients can reach it. The
> current deployment does not authenticate OTLP requests. Treat the endpoint as
> an ingestion endpoint, avoid sending sensitive prompt content, and add an
> authenticated gateway or ingress restrictions before wider production use.

## Architecture

```text
VS Code with GitHub Copilot
        | OTLP/HTTP over HTTPS
        v
Azure Container Apps: OpenTelemetry Collector
        | Azure Monitor exporter
        v
Workspace-based Application Insights
        | KQL through the Azure Monitor data source
        v
Azure Managed Grafana
```

The Container Apps environment is integrated with a delegated subnet. A
user-assigned managed identity pulls the collector image from Azure Container
Registry and resolves the Application Insights connection string from Key Vault.
Key Vault disables public network access and is reached through a private
endpoint and private DNS zone.

See the [solution dataflow](docs/dataflow-diagram.md) for runtime and dependency
flows.

## Repository Contents

| Path | Purpose |
| --- | --- |
| `Dockerfile` | Builds the collector image with the repository configuration |
| `config.yaml` | Defines OTLP receivers, processors, and Azure Monitor and debug exporters |
| `grafana-agent-usage-geo.json` | Defines the importable Grafana dashboard |
| `KQL-queries.txt` | Provides exploratory Application Insights queries |
| `terraform/` | Provisions the Azure resources and optional dashboard import |
| `wsl-setup-otel.sh` | Sets OTLP environment variables and optional organization metadata before VS Code starts |
| `docs/` | Contains architecture, deployment, setup, metadata, and filtering guides |
| `.github/agents/` | Contains sample custom agents for generating test telemetry |
| `.github/skills/` | Contains sample skills for generating test telemetry |

## Reference Deployment

The Terraform configuration and checked-in state describe the following deployed
shape in UK South:

* Resource group `copilot-dashboard-rg`
* Log Analytics workspace with 365-day retention
* Workspace-based Application Insights resource
* Virtual network with a `/23` Container Apps subnet and `/24` private endpoint subnet
* Key Vault with RBAC, public access disabled, and a private endpoint
* Standard Azure Container Registry with admin access disabled
* Consumption-plan Container Apps environment with Log Analytics integration
* OpenTelemetry Collector Container App with public HTTP ingress targeting port `4318`
* User-assigned collector identity with `AcrPull` and `Key Vault Secrets User`
* Standard Azure Managed Grafana 12 with a system-assigned identity
* `Monitoring Reader` for Grafana at resource-group scope

## Prerequisites

* Azure subscription permissions to create resources and role assignments
* Azure CLI authenticated to the target tenant and subscription
* Azure CLI Managed Grafana extension (`az extension add --name amg`)
* Terraform 1.7 or later
* Docker
* VS Code with GitHub Copilot Business or Enterprise
* Permission to register the `Microsoft.App`, `Microsoft.Dashboard`, and
  `Microsoft.AlertsManagement` resource providers

## Deploy

### 1. Select the Azure subscription

```powershell
az login --tenant <tenant-id>
az account set --subscription <subscription-id>
$env:TF_VAR_subscription_id = az account show --query id -o tsv
```

### 2. Bootstrap the registry

```powershell
az provider register --namespace Microsoft.AlertsManagement --wait
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.Dashboard --wait

terraform -chdir=terraform init
terraform -chdir=terraform validate
terraform -chdir=terraform apply `
  '-target=azurerm_resource_group.rg' `
  '-target=azurerm_container_registry.acr'
```

### 3. Build and push an immutable collector image

```powershell
$ACR = terraform -chdir=terraform output -raw acr_login_server
$ACR_NAME = $ACR.Split('.')[0]
$IMAGE_TAG = git rev-parse --short HEAD

az acr login --name $ACR_NAME
docker build -t "${ACR}/otel-collector:${IMAGE_TAG}" .
docker push "${ACR}/otel-collector:${IMAGE_TAG}"
```

### 4. Apply the complete deployment

```powershell
terraform -chdir=terraform plan -var "image_tag=$IMAGE_TAG" -out=tfplan
terraform -chdir=terraform apply tfplan
```

### 5. Configure VS Code

Get the Container App revision hostname:

```powershell
terraform -chdir=terraform output -raw container_app_fqdn
```

Add it to VS Code User Settings and restart VS Code:

```json
{
  "github.copilot.chat.otel.enabled": true,
  "github.copilot.chat.otel.exporterType": "otlp-http",
  "github.copilot.chat.otel.otlpEndpoint": "https://<container-app-fqdn>"
}
```

### 6. Import the dashboard

Terraform can run the Azure CLI import as a dedicated optional stage:

```powershell
terraform -chdir=terraform apply `
  '-target=terraform_data.grafana_dashboard_import' `
  "-var=image_tag=$IMAGE_TAG" `
  '-var=enable_grafana_dashboard_import=true'
```

The Grafana managed identity receives `Monitoring Reader` on the resource group.
In Grafana, configure an Azure Monitor data source with managed identity
authentication, then import `grafana-agent-usage-geo.json` if the Terraform import
stage is not used.

## Verify

Check the active revision and collector logs:

```powershell
az containerapp revision list `
  --name copilot-dash-collector `
  --resource-group copilot-dashboard-rg `
  --query "[].{name:name,active:properties.active,traffic:properties.trafficWeight}" `
  --output table

az containerapp logs show `
  --name copilot-dash-collector `
  --resource-group copilot-dashboard-rg `
  --tail 100
```

After using Copilot Chat, query Application Insights:

```kusto
dependencies
| where timestamp > ago(1h)
| take 20
```

Allow several minutes for ingestion before checking the Grafana panels.

## Documentation

* [Terraform deployment guide](docs/plan.md)
* [Solution dataflow](docs/dataflow-diagram.md)
* [Manual Azure CLI setup](docs/manual-setup.md)
* [Azure Portal setup](docs/portal-setup.md)
* [Adding organization metadata](docs/adding-extra-metadata.md)
* [Filtering sensitive telemetry](docs/filtering-telemetry.md)

## Tear Down

```powershell
terraform -chdir=terraform destroy -var "image_tag=$IMAGE_TAG"
```
