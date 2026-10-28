---
title: Azure Portal Setup
description: Configure the GitHub Copilot usage dashboard through the Azure Portal while preserving the deployed network and identity design
ms.date: 2026-10-28
ms.topic: tutorial
---

## Overview

Use this guide when you need to inspect or recreate the solution through the Azure
Portal. The target architecture remains the same as the Terraform deployment:

1. Resource group in UK South
2. Log Analytics workspace with 365-day retention
3. Workspace-based Application Insights
4. Virtual network with delegated and private endpoint subnets
5. Key Vault with RBAC and public access disabled
6. Key Vault private endpoint and private DNS zone
7. Standard Azure Container Registry with a custom collector image
8. User-assigned managed identity
9. VNet-integrated Container Apps environment and public collector app
10. Azure Managed Grafana with managed identity access to Azure Monitor

> [!IMPORTANT]
> Do not use an Azure Files-mounted collector configuration for this repository.
> The deployed solution builds `config.yaml` into the image through the
> [Dockerfile](../Dockerfile).

## 1. Monitoring Resources

Create `copilot-dashboard-rg` in UK South. In that resource group:

* Create `copilot-dash-law` as a Log Analytics workspace
* Set workspace retention to 365 days under Usage and estimated costs
* Create `copilot-dash-ai` as workspace-based Application Insights
* Select `copilot-dash-law` as the backing workspace

Copy the Application Insights connection string for the Key Vault secret.

## 2. Virtual Network

Create `copilot-dash-vnet` with address space `10.20.0.0/16` and these subnets:

| Subnet | Prefix | Configuration |
| --- | --- | --- |
| `copilot-dash-aca-snet` | `10.20.0.0/23` | Delegate to `Microsoft.App/environments` |
| `copilot-dash-pe-snet` | `10.20.2.0/24` | Use for private endpoints |

The Container Apps subnet must be dedicated to the environment.

## 3. Key Vault and Private Endpoint

Create `copilot-dash-kv` with:

* Standard tier
* Azure RBAC permission model
* Seven-day soft-delete retention
* Purge protection matching your organizational policy

For a portal-only bootstrap, grant yourself `Key Vault Secrets Officer`, add
`AppInsightsConnectionString`, and then disable public network access. The
Terraform deployment creates the secret through the ARM control plane and does
not need this temporary public data-plane path.

Create a private endpoint named `copilot-dash-kv-pe` in the private endpoint
subnet. Select the `vault` subresource and integrate it with the private DNS zone
`privatelink.vaultcore.azure.net`. Link that zone to `copilot-dash-vnet`.

After the private endpoint and DNS link are healthy, confirm public network access
is disabled. Future secret changes require a client connected to the private
endpoint or an ARM control-plane deployment such as the repository Terraform.

## 4. Registry and Image

Create the Standard registry `copilotdashacr` with the admin account disabled.
The Portal does not build this repository's Dockerfile directly. Build and push an
immutable image tag from a trusted workstation or CI runner:

```powershell
$ACR = "copilotdashacr.azurecr.io"
$IMAGE_TAG = git rev-parse --short HEAD
az acr login --name copilotdashacr
docker build -t "${ACR}/otel-collector:${IMAGE_TAG}" .
docker push "${ACR}/otel-collector:${IMAGE_TAG}"
```

## 5. Collector Identity

Create the user-assigned managed identity `copilot-dash-collector-uai`. Grant it:

* `AcrPull` on `copilotdashacr`
* `Key Vault Secrets User` on `copilot-dash-kv`

Use resource-level scopes to preserve least privilege.

## 6. Container Apps Environment

Create `copilot-dash-cae` with:

* Region set to UK South
* `copilot-dash-law` as the Log Analytics destination
* `copilot-dash-aca-snet` as the infrastructure subnet
* Public network access enabled for the collector ingress
* Zone redundancy disabled unless the region, subnet, and workload requirements support it

## 7. Collector Container App

Create `copilot-dash-collector` in the environment:

* Assign only `copilot-dash-collector-uai`
* Select the ACR image and immutable tag pushed in the previous step
* Configure registry authentication with the user-assigned identity
* Allocate `0.5` CPU and `1 GiB` memory
* Use single revision mode
* Enable external ingress with HTTP transport and target port `4318`
* Keep insecure connections disabled

Add a Container App secret:

| Setting | Value |
| --- | --- |
| Name | `appinsights-conn-str` |
| Source | Key Vault reference |
| Secret URL | `https://copilot-dash-kv.vault.azure.net/secrets/AppInsightsConnectionString` |
| Identity | `copilot-dash-collector-uai` |

Add an environment variable named `APPLICATIONINSIGHTS_CONNECTION_STRING` that
references `appinsights-conn-str`.

The current Terraform defaults permit scaling from zero to ten replicas. Set a
minimum replica count of one if cold-start latency is unacceptable.

## 8. Azure Managed Grafana

Create `copilot-dash-grafana` with:

* Standard SKU
* Grafana major version 12
* System-assigned managed identity
* Public network access enabled

Grant the Grafana identity `Monitoring Reader` on `copilot-dashboard-rg`. Grant
administrators `Grafana Admin` on the Grafana resource and viewers `Grafana
Viewer` where needed.

In Grafana:

1. Add the Azure Monitor data source
2. Select managed identity authentication
3. Select the target subscription
4. Save and test the data source
5. Import `grafana-agent-usage-geo.json`
6. Map `DS_AZURE_MONITOR` to the configured data source

## 9. Configure and Verify VS Code

Copy the Container App application URL and configure VS Code as shown in the
[README](../README.md). Confirm the revision is healthy, telemetry reaches
Application Insights, and dashboard panels populate before onboarding additional
users.

## Remove the Deployment

Delete `copilot-dashboard-rg` only after confirming it contains no unrelated
resources. Soft-deleted Key Vault data can remain recoverable according to the
configured retention policy.
