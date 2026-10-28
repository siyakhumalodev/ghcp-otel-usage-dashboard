---
title: Estimate Cost and Operate the Dashboard
description: Model Azure service costs, measure telemetry ingestion, and apply operational controls to the Copilot observability solution
ms.date: 2026-10-28
ms.topic: how-to
---

## Cost Boundary

Separate telemetry-platform cost from reporting-tool cost. Application Insights
and Log Analytics ingestion and retention apply whether the reporting layer is
Azure Managed Grafana or Power BI. Power BI licensing, Fabric capacity, and
semantic-model storage are separate from the Azure resources provisioned by this
repository.

The main cost categories are:

* Log Analytics ingestion and retention
* Azure Managed Grafana provisioned units and active users
* Container Apps collector compute and requests
* Azure Container Registry
* Key Vault operations
* Private Endpoint hours and processed data
* Optional reporting services such as Power BI or Microsoft Fabric

Prices vary by region, agreement, currency, date, free allowance, and commitment
tier. Validate current rates with the Azure Pricing Calculator before treating an
estimate as a budget.

## Start With Measured Ingestion

Use actual workspace usage when the deployment has representative traffic. A
developer-count estimate is useful before deployment, but it does not account for
differences in session length, agent behavior, models, tools, or debug output.

Summarize recent billable ingestion from the Log Analytics `Usage` table:

```kusto
Usage
| where TimeGenerated >= startofday(ago(30d))
| where IsBillable == true
| summarize IngestedGB = sum(Quantity) / 1000 by DataType
| order by IngestedGB desc
```

Compare this result with Azure Cost Management. The `Usage` table can have
ingestion delay and does not replace the invoice or Cost Management export.

For predeployment planning, calculate base telemetry volume as:

```text
Base GB = developers * working days * MB per developer per day
          * retained sampling percentage / 1024
```

If collector debug output is ingested into Log Analytics, estimate it separately:

```text
Debug GB = Base GB * measured debug amplification
Monthly ingestion GB = Base GB + Debug GB
```

Do not assume an amplification value. Measure the deployment with the debug
exporter enabled and disabled under comparable traffic.

## Understand Debug Duplication

The current collector exports traces to Azure Monitor and also sends trace details
to the `debug` exporter. Debug output is written to Container Apps console logs.
When environment logs enter the same workspace, verbose output can duplicate or
amplify billable ingestion and can expose attributes that were intended only for
troubleshooting.

Use the debug exporter for bounded diagnostic windows. Remove it from the traces
pipeline or reduce its verbosity for routine production operation, then build and
deploy a new immutable collector image.

See [Filter sensitive telemetry](filtering-telemetry.md) for collector processor
examples and deployment validation.

## Build a Directional Estimate

Collect these inputs before estimating monthly cost:

* Telemetry developers, working days, measured volume, sampling, and debug overhead
* Log Analytics ingestion, free allowance, interactive retention, and archive retention
* Managed Grafana provisioned units, unit-hours, and monthly active users
* Container Apps active hours, vCPU, memory, requests, and free allowances
* Container Registry tier, Key Vault operations, and private endpoint usage
* Power BI licensing or Fabric capacity when those reporting services are used

Calculate each category with its current regional rate and keep the assumptions
beside the result. Report both the monthly total and cost per developer, but do not
present per-developer cost as a chargeback rate unless the allocation method has
been approved.

## Identify the Largest Contributors

The largest category depends on actual usage. Managed Grafana can dominate a
small deployment with many report users, while ingestion can dominate a large or
verbose deployment. Collector compute can increase when minimum replicas prevent
scale-to-zero or when processing, filtering, and batching require more resources.

Review these levers in order:

1. Measure ingestion rather than relying on a per-developer proxy.
2. Compare ingestion with the debug exporter enabled and disabled.
3. Remove unnecessary attributes and spans before export.
4. Apply sampling only after identifying which traces must remain complete.
5. Bound dashboard time windows, result sizes, and refresh intervals.
6. Match Log Analytics retention to approved operational and compliance needs.
7. Review Grafana active users and provisioned units.
8. Review Container Apps replica bounds, CPU, memory, and cold-start tolerance.

Cost reduction must preserve the telemetry needed to answer approved questions.
Validate dashboards and investigations after every filtering or sampling change.

## Secure the Ingestion Boundary

The Terraform reference deployment exposes OTLP/HTTP over public HTTPS so VS Code
clients can reach the collector. TLS protects transport, but the current ingress
does not authenticate senders. Unwanted telemetry can consume collector compute
and Log Analytics ingestion.

Before wider production use, evaluate:

* An authenticated gateway in front of the collector
* Container Apps ingress restrictions where client egress ranges are stable
* Request and payload size limits
* Rate controls and abuse monitoring
* Approved attribute allowlists and sensitive-field removal
* Alerts for unexpected ingestion growth and collector errors

Do not place a static secret in repository files or shared VS Code settings.

## Establish an Operating Baseline

Record a baseline after deployment and after material configuration changes:

* Daily ingestion by data type
* Collector replica count, CPU, memory, restarts, and rejected telemetry
* Export failures and throttling
* Query latency and dashboard errors
* Attribute coverage for agent, session, token, identity, and repository fields
* Grafana active users and provisioned capacity
* Retention configuration and archive volume
* Monthly Azure cost by service and resource group

Correlate cost changes with collector image versions, VS Code releases, new
dashboard panels, and changes to identity capture or debug logging.

## Review on a Schedule

Use a recurring operational review:

### Weekly

* Check collector health, export failures, and ingestion anomalies
* Verify that critical dashboard queries still return current data
* Investigate unexpected attribute or schema changes

### Monthly

* Reconcile measured ingestion with Azure Cost Management
* Review Grafana users, query load, and dashboard refresh settings
* Compare actual cost with the documented estimate
* Check identity and repository field completeness and approved use

### Quarterly

* Reconfirm retention, access, and data-minimization requirements
* Review role assignments and dashboard audiences
* Test restoration or recreation from Terraform and immutable images
* Revalidate regional prices and service capabilities

## References

* [Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/)
* [Azure Container Apps pricing](https://azure.microsoft.com/pricing/details/container-apps/)
* [Azure Managed Grafana pricing](https://azure.microsoft.com/pricing/details/managed-grafana/)
* [Azure Container Registry pricing](https://azure.microsoft.com/pricing/details/container-registry/)
* [Azure Key Vault pricing](https://azure.microsoft.com/pricing/details/key-vault/)
* [Azure Private Link pricing](https://azure.microsoft.com/pricing/details/private-link/)
