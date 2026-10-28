---
title: Solution Dataflow Architecture
description: Runtime telemetry and supporting dependency flows for the GitHub Copilot usage dashboard
ms.date: 2026-10-28
ms.topic: architecture
---

## Runtime Dataflow

```mermaid
flowchart TB
    vscode["VS Code<br/>GitHub Copilot"]
    viewer["Dashboard viewer"]

    subgraph rg["Azure resource group"]
        direction TB
        acr[("Azure Container Registry")]
        identity["Collector user-assigned identity"]
        kv["Azure Key Vault"]
        ai["Application Insights"]
        law[("Log Analytics workspace")]
        grafana["Azure Managed Grafana"]

        subgraph vnet["Virtual network"]
            direction TB
            subgraph aca_subnet["Container Apps delegated subnet"]
                subgraph collector["OpenTelemetry Collector on Azure Container Apps"]
                    direction TB
                    receiver["OTLP receiver"]
                    processors["Batch and attribute processors"]
                    monitor_exporter["Azure Monitor exporter"]
                    debug_exporter["Debug exporter"]
                end
            end

            subgraph pe_subnet["Private endpoint subnet"]
                kv_pe["Key Vault private endpoint"]
            end
        end

        aca_logs["Container Apps logs"]
    end

    vscode -->|"OTLP/HTTP traces and metrics<br/>public HTTPS ingress"| receiver
    receiver --> processors
    processors -->|"traces and metrics"| monitor_exporter
    monitor_exporter -->|"Azure Monitor ingestion"| ai
    ai -->|"workspace-based telemetry"| law
    processors -->|"traces"| debug_exporter
    debug_exporter --> aca_logs
    aca_logs --> law
    law <-->|"KQL queries and results"| grafana
    grafana -->|"HTTPS"| viewer

    acr -. "collector image" .-> collector
    identity -. "AcrPull" .-> acr
    identity -. "Key Vault Secrets User" .-> kv
    kv -. "Application Insights connection string" .-> kv_pe
    kv_pe -. "private secret resolution" .-> collector
```

## Key Relationships

* Azure Container Apps terminates TLS and forwards external HTTPS requests to the
  collector's OTLP/HTTP receiver on target port `4318`.
* The collector accepts OTLP/gRPC on `4317` inside the container, but that port is
  not exposed by the current Container App ingress.
* The attributes processor adds `environment=prod`; the batch processor runs
  before export.
* Traces go to both the `azure_monitor` and `debug` exporters. Metrics go only to
  `azure_monitor`.
* Application Insights is workspace-based and stores queryable telemetry in the
  Log Analytics workspace.
* Azure Managed Grafana queries Azure Monitor with its system-assigned identity.
* The collector's user-assigned identity pulls from ACR and resolves a versionless
  Key Vault secret reference.
* Key Vault public network access is disabled. Private DNS resolves the vault to
  its private endpoint from the Container Apps virtual network.

## Security Boundary

The Azure dependencies use managed identity and private Key Vault connectivity,
but the OTLP ingestion endpoint remains public and unauthenticated. Network
restrictions or an authenticated gateway are required when anonymous ingestion is
not acceptable.

## Scope

Terraform control-plane traffic, Docker image pushes, and the optional dashboard
import are deployment-time flows and are not shown as runtime paths.
