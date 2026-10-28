---
title: Add Organization Metadata
description: Add squad and product resource attributes to GitHub Copilot OpenTelemetry from WSL
ms.date: 2026-10-28
ms.topic: how-to
---

## Purpose

The [WSL setup script](../wsl-setup-otel.sh) sets OpenTelemetry environment
variables before VS Code starts. It can attach `org.squad` and `org.product`
resource attributes so dashboard queries can group activity by organizational
context.

Only add metadata approved for telemetry collection. Do not use these fields for
secrets, customer data, prompt content, or direct personal identifiers.

## Get the Current Collector Endpoint

For the Terraform deployment, retrieve the current revision FQDN:

```bash
terraform -chdir=terraform output -raw container_app_fqdn
```

You can also use the stable application FQDN from the Container App Overview page.
The script intentionally has no repository-specific default endpoint because the
hostname changes between deployments.

## Start VS Code with Metadata

Source the script from WSL so its exports remain in the current shell:

```bash
source ./wsl-setup-otel.sh
```

Provide values when prompted:

```text
OpenTelemetry environment setup for WSL
Collector endpoint: https://<container-app-fqdn>
Squad name: Platform Engineering
Product name: Copilot Dashboard

Proposed values:
  OTEL_EXPORTER_OTLP_ENDPOINT=https://<container-app-fqdn>
  OTEL_EXPORTER_OTLP_PROTOCOL=otlp-http
  OTEL_RESOURCE_ATTRIBUTES=org.squad=Platform Engineering,org.product=Copilot Dashboard

Apply these values to the current shell? [Y/n]: Y
```

Launch VS Code from that shell after applying the values:

```bash
code .
```

The script sets:

* `OTEL_EXPORTER_OTLP_ENDPOINT` to the current Container App HTTPS endpoint
* `OTEL_EXPORTER_OTLP_PROTOCOL` to `otlp-http`
* `OTEL_RESOURCE_ATTRIBUTES` to the supplied squad and product values

Values containing commas, quotation marks, or backslashes are escaped before the
resource attribute list is created.

## Verify

Use Copilot Chat, allow time for ingestion, and inspect a recent dependency in
Application Insights:

```kusto
dependencies
| where timestamp > ago(30m)
| project timestamp, name, customDimensions
| take 20
```

Confirm that the emitted dimensions contain the expected metadata keys before
adding them to dashboard queries.

## Troubleshoot

* Run the script with `source`; executing it directly can only print export commands
* Start VS Code after applying the variables because the editor reads its process environment at startup
* Use an `https://` Container App endpoint without appending port `4318`
* Recheck the endpoint after recreating the Container App environment
