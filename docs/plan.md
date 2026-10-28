---
title: Terraform Deployment Guide
description: Build, deploy, verify, update, and remove the GitHub Copilot usage dashboard with Terraform
ms.date: 2026-10-28
ms.topic: tutorial
---

## Deployment Model

The authoritative infrastructure definition is split across
[main.tf](../terraform/main.tf), [variables.tf](../terraform/variables.tf), and
[outputs.tf](../terraform/outputs.tf). Do not copy Terraform resources from this
guide into a second configuration because duplicated snippets drift from the
deployed design.

Terraform creates:

* Resource group in UK South by default
* Virtual network and delegated Container Apps subnet
* Private endpoint subnet, Key Vault private endpoint, and private DNS zone
* Log Analytics workspace with 365-day retention
* Workspace-based Application Insights
* Key Vault with public access disabled and RBAC authorization enabled
* Standard Azure Container Registry
* User-assigned identity for collector startup dependencies
* VNet-integrated Container Apps environment and collector app
* Azure Managed Grafana 12 and required role assignments

## Prerequisites

* Terraform 1.7 or later
* Azure CLI authenticated to the target tenant and subscription
* Docker
* Permission to create resources and Azure role assignments
* Azure CLI `amg` extension when importing the dashboard

## 1. Authenticate and Register Providers

```powershell
az login --tenant <tenant-id>
az account set --subscription <subscription-id>
$env:TF_VAR_subscription_id = az account show --query id -o tsv

az provider register --namespace Microsoft.AlertsManagement --wait
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.Dashboard --wait
```

## 2. Initialize and Validate

```powershell
terraform -chdir=terraform init
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
```

## 3. Bootstrap ACR

The Container App cannot start until its image exists. Create the resource group
and registry first:

```powershell
terraform -chdir=terraform apply `
  '-target=azurerm_resource_group.rg' `
  '-target=azurerm_container_registry.acr'
```

Targeted apply is used only for this bootstrap dependency. Use a normal plan and
apply for subsequent changes.

## 4. Build and Push the Image

```powershell
$ACR = terraform -chdir=terraform output -raw acr_login_server
$ACR_NAME = $ACR.Split('.')[0]
$IMAGE_TAG = git rev-parse --short HEAD

az acr login --name $ACR_NAME
docker build -t "${ACR}/otel-collector:${IMAGE_TAG}" .
docker push "${ACR}/otel-collector:${IMAGE_TAG}"
```

Use an immutable tag such as a commit SHA or release identifier. The Terraform
default is `latest` for convenience, but repeatable deployments should always pass
`image_tag` explicitly.

## 5. Deploy the Complete Solution

```powershell
terraform -chdir=terraform plan -var "image_tag=$IMAGE_TAG" -out=tfplan
terraform -chdir=terraform apply tfplan
```

The apply writes the Application Insights connection string into Key Vault by
using the ARM control plane. This avoids requiring public Key Vault data-plane
access during deployment. The collector receives a versionless Key Vault secret
reference through its user-assigned identity.

## 6. Configure VS Code

```powershell
$FQDN = terraform -chdir=terraform output -raw container_app_fqdn
$FQDN
```

Configure VS Code User Settings:

```json
{
  "github.copilot.chat.otel.enabled": true,
  "github.copilot.chat.otel.exporterType": "otlp-http",
  "github.copilot.chat.otel.otlpEndpoint": "https://<container-app-fqdn>"
}
```

Restart VS Code after changing telemetry settings or process-level OpenTelemetry
resource attributes.

## 7. Import the Dashboard

Install the CLI extension and run the optional Terraform stage:

```powershell
az extension add --name amg --upgrade

terraform -chdir=terraform apply `
  '-target=terraform_data.grafana_dashboard_import' `
  "-var=image_tag=$IMAGE_TAG" `
  '-var=enable_grafana_dashboard_import=true'
```

The import uses `--overwrite true` and reruns when the dashboard JSON hash changes.
The Azure Monitor data source in Grafana must use managed identity authentication.

## 8. Verify

```powershell
terraform -chdir=terraform output

az containerapp show `
  --name copilot-dash-collector `
  --resource-group copilot-dashboard-rg `
  --query "{fqdn:properties.configuration.ingress.fqdn,revision:properties.latestRevisionName}" `
  --output yaml

az containerapp logs show `
  --name copilot-dash-collector `
  --resource-group copilot-dashboard-rg `
  --tail 100
```

Use Copilot Chat, then query Application Insights:

```kusto
dependencies
| where timestamp > ago(1h)
| summarize events=count() by bin(timestamp, 5m)
| order by timestamp desc
```

## Update

Build and push a new immutable image tag, then apply with that tag:

```powershell
$IMAGE_TAG = git rev-parse --short HEAD
docker build -t "${ACR}/otel-collector:${IMAGE_TAG}" .
docker push "${ACR}/otel-collector:${IMAGE_TAG}"
terraform -chdir=terraform apply -var "image_tag=$IMAGE_TAG"
```

## Remove

```powershell
terraform -chdir=terraform destroy -var "image_tag=$IMAGE_TAG"
```

Key Vault soft delete can retain the vault name after resource deletion. Purging a
soft-deleted vault is a separate destructive operation and is not performed by
this repository.
