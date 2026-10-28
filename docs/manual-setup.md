---
title: Manual Azure CLI Setup
description: Recreate the Terraform deployment architecture with Azure CLI commands and a custom collector image
ms.date: 2026-10-28
ms.topic: tutorial
---

## Scope

This guide recreates the same architecture as the Terraform deployment without
using Terraform. It uses a custom image from Azure Container Registry, a
user-assigned managed identity, a VNet-integrated Container Apps environment, and
private Key Vault access.

> [!NOTE]
> Terraform remains the recommended path because it records resource dependencies,
> role assignments, and network configuration in source control. Use this guide
> for investigation or environments where Terraform is unavailable.

## Prerequisites

* Azure CLI with the `containerapp` and `amg` extensions
* Docker
* Permission to create resources, private endpoints, and role assignments
* Bash, Azure Cloud Shell, or equivalent command substitution support

Set reusable values:

```bash
RG="copilot-dashboard-rg"
LOCATION="uksouth"
PREFIX="copilot-dash"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
```

## 1. Create Monitoring Resources

```bash
az group create --name "$RG" --location "$LOCATION"

az monitor log-analytics workspace create \
  --resource-group "$RG" \
  --workspace-name "${PREFIX}-law" \
  --location "$LOCATION" \
  --retention-time 365

LAW_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RG" \
  --workspace-name "${PREFIX}-law" \
  --query id -o tsv)
LAW_CUSTOMER_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RG" \
  --workspace-name "${PREFIX}-law" \
  --query customerId -o tsv)
LAW_SHARED_KEY=$(az monitor log-analytics workspace get-shared-keys \
  --resource-group "$RG" \
  --workspace-name "${PREFIX}-law" \
  --query primarySharedKey -o tsv)

az monitor app-insights component create \
  --app "${PREFIX}-ai" \
  --location "$LOCATION" \
  --resource-group "$RG" \
  --workspace "$LAW_ID" \
  --application-type web
```

## 2. Create the Network

```bash
az network vnet create \
  --resource-group "$RG" \
  --name "${PREFIX}-vnet" \
  --location "$LOCATION" \
  --address-prefixes 10.20.0.0/16

az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "${PREFIX}-vnet" \
  --name "${PREFIX}-aca-snet" \
  --address-prefixes 10.20.0.0/23 \
  --delegations Microsoft.App/environments

az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "${PREFIX}-vnet" \
  --name "${PREFIX}-pe-snet" \
  --address-prefixes 10.20.2.0/24
```

## 3. Create Private Key Vault Access

```bash
az keyvault create \
  --name "${PREFIX}-kv" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --enable-rbac-authorization true \
  --public-network-access Enabled

KV_ID=$(az keyvault show --name "${PREFIX}-kv" --resource-group "$RG" --query id -o tsv)
DEPLOYER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

az role assignment create \
  --role "Key Vault Secrets Officer" \
  --assignee-object-id "$DEPLOYER_OBJECT_ID" \
  --scope "$KV_ID"

APPINSIGHTS_CONNECTION_STRING=$(az monitor app-insights component show \
  --app "${PREFIX}-ai" \
  --resource-group "$RG" \
  --query connectionString -o tsv)

az keyvault secret set \
  --vault-name "${PREFIX}-kv" \
  --name AppInsightsConnectionString \
  --value "$APPINSIGHTS_CONNECTION_STRING"

az network private-dns zone create \
  --resource-group "$RG" \
  --name privatelink.vaultcore.azure.net

az network private-dns link vnet create \
  --resource-group "$RG" \
  --zone-name privatelink.vaultcore.azure.net \
  --name "${PREFIX}-kv-dns-link" \
  --virtual-network "${PREFIX}-vnet" \
  --registration-enabled false

PE_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RG" \
  --vnet-name "${PREFIX}-vnet" \
  --name "${PREFIX}-pe-snet" \
  --query id -o tsv)

az network private-endpoint create \
  --resource-group "$RG" \
  --name "${PREFIX}-kv-pe" \
  --location "$LOCATION" \
  --subnet "$PE_SUBNET_ID" \
  --private-connection-resource-id "$KV_ID" \
  --group-id vault \
  --connection-name "${PREFIX}-kv-connection"

az network private-endpoint dns-zone-group create \
  --resource-group "$RG" \
  --endpoint-name "${PREFIX}-kv-pe" \
  --name default \
  --private-dns-zone privatelink.vaultcore.azure.net \
  --zone-name privatelink.vaultcore.azure.net

az keyvault update \
  --name "${PREFIX}-kv" \
  --resource-group "$RG" \
  --public-network-access Disabled
```

The manual path briefly enables public Key Vault access for secret bootstrap, then
disables it after private DNS and the private endpoint are configured. The
Terraform path avoids that temporary exposure by creating the secret through the
ARM control plane.

## 4. Build the Collector Image

```bash
ACR_NAME="${PREFIX//-/}acr"
IMAGE_TAG=$(git rev-parse --short HEAD)

az acr create \
  --name "$ACR_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --sku Standard \
  --admin-enabled false

az acr login --name "$ACR_NAME"
ACR_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
docker build -t "${ACR_SERVER}/otel-collector:${IMAGE_TAG}" .
docker push "${ACR_SERVER}/otel-collector:${IMAGE_TAG}"
```

## 5. Create Identity and Container Apps

```bash
az identity create \
  --name "${PREFIX}-collector-uai" \
  --resource-group "$RG" \
  --location "$LOCATION"

IDENTITY_ID=$(az identity show \
  --name "${PREFIX}-collector-uai" \
  --resource-group "$RG" \
  --query id -o tsv)
IDENTITY_PRINCIPAL=$(az identity show \
  --name "${PREFIX}-collector-uai" \
  --resource-group "$RG" \
  --query principalId -o tsv)
ACR_ID=$(az acr show --name "$ACR_NAME" --query id -o tsv)

az role assignment create --role AcrPull --assignee-object-id "$IDENTITY_PRINCIPAL" --scope "$ACR_ID"
az role assignment create --role "Key Vault Secrets User" --assignee-object-id "$IDENTITY_PRINCIPAL" --scope "$KV_ID"

ACA_SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RG" \
  --vnet-name "${PREFIX}-vnet" \
  --name "${PREFIX}-aca-snet" \
  --query id -o tsv)

az containerapp env create \
  --name "${PREFIX}-cae" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --logs-workspace-id "$LAW_CUSTOMER_ID" \
  --logs-workspace-key "$LAW_SHARED_KEY" \
  --infrastructure-subnet-resource-id "$ACA_SUBNET_ID"
```

Create the Container App with the pushed image, user-assigned identity, external
HTTP ingress, target port `4318`, and a Key Vault-backed secret named
`appinsights-conn-str`. The corresponding environment variable must be
`APPLICATIONINSIGHTS_CONNECTION_STRING=secretref:appinsights-conn-str`.

Azure CLI arguments for user-assigned registry identity and Key Vault references
change over time. Confirm the generated configuration before deployment, or use
the repository Terraform where these relationships are tested together.

## 6. Create Grafana

```bash
az grafana create \
  --name "${PREFIX}-grafana" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --sku Standard

GRAFANA_PRINCIPAL=$(az grafana show \
  --name "${PREFIX}-grafana" \
  --resource-group "$RG" \
  --query identity.principalId -o tsv)
RG_ID=$(az group show --name "$RG" --query id -o tsv)

az role assignment create \
  --role "Monitoring Reader" \
  --assignee-object-id "$GRAFANA_PRINCIPAL" \
  --scope "$RG_ID"

az grafana dashboard import \
  --name "${PREFIX}-grafana" \
  --resource-group "$RG" \
  --definition @grafana-agent-usage-geo.json \
  --overwrite true
```

Configure the Azure Monitor data source to use managed identity authentication.

## 7. Verify and Remove

Follow the verification steps in the [README](../README.md). Remove all resources
when finished:

```bash
az group delete --name "$RG" --yes
```

Deleting the resource group is destructive. Key Vault soft delete can retain the
vault name after resource deletion.
