---
title: Filter Sensitive Telemetry
description: Add optional OpenTelemetry Collector processors to remove or transform sensitive attributes before Azure Monitor export
ms.date: 2026-10-28
ms.topic: how-to
---

## Current Configuration

The deployed [collector configuration](../config.yaml) currently uses only:

* `batch` processing
* An `attributes` processor that adds `environment=prod`
* The `azure_monitor` exporter for traces and metrics
* The `debug` exporter for traces

It does not currently redact, hash, filter, or sample telemetry. The examples in
this guide are optional hardening changes and are not active until added to
`config.yaml`, validated, built into a new image, and deployed.

> [!CAUTION]
> The trace debug exporter can write detailed telemetry to Container Apps logs.
> Remove it or reduce its verbosity after troubleshooting if those logs could
> contain sensitive attributes.

## Inspect Before Filtering

Export a small approved sample and inspect the actual attribute keys emitted by
your current VS Code and Copilot versions. Do not assume example key names exist.
Filtering a nonexistent key has no effect, while broad regular expressions can
discard useful telemetry.

## Remove Known Attributes

Use a named attributes processor for exact keys:

```yaml
processors:
  attributes/sanitize:
    actions:
      - key: user.email
        action: delete
      - key: http.request.header.authorization
        action: delete
      - key: enduser.id
        action: hash

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [attributes/sanitize, batch, attributes]
      exporters: [azure_monitor]
    metrics:
      receivers: [otlp]
      processors: [attributes/sanitize, batch, attributes]
      exporters: [azure_monitor]
```

Processor order matters. Sanitize before batching and exporting. The final
`attributes` processor preserves the repository's `environment=prod` enrichment.

## Drop Matching Spans

Use the filter processor when the entire span must be removed:

```yaml
processors:
  filter/sensitive:
    error_mode: ignore
    traces:
      span:
        - 'IsMatch(attributes["http.request.header.authorization"], ".+")'
        - 'IsMatch(attributes["db.statement"], "(?i).*password.*")'

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [filter/sensitive, batch, attributes]
      exporters: [azure_monitor]
```

Test each OpenTelemetry Transformation Language expression against the collector
version used by the Docker image. Processor syntax and available functions can
change between collector releases.

## Transform Values

Use a transform processor when analytics require the event but not the original
value:

```yaml
processors:
  transform/sanitize:
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          - set(attributes["user.email"], "[REDACTED]") where attributes["user.email"] != nil
```

Prefer deleting exact fields over complex regular expressions. Regex-heavy
transform rules consume CPU and are more difficult to validate.

## Validate and Deploy

Validate with the same collector image used by the Dockerfile:

```powershell
docker run --rm `
  --volume "${PWD}/config.yaml:/etc/otelcol-contrib/config.yaml:ro" `
  otel/opentelemetry-collector-contrib:latest `
  validate --config=/etc/otelcol-contrib/config.yaml
```

Then build and deploy a new immutable image tag:

```powershell
$ACR = terraform -chdir=terraform output -raw acr_login_server
$IMAGE_TAG = "sanitize-$(git rev-parse --short HEAD)"
docker build -t "${ACR}/otel-collector:${IMAGE_TAG}" .
docker push "${ACR}/otel-collector:${IMAGE_TAG}"
terraform -chdir=terraform apply -var "image_tag=$IMAGE_TAG"
```

Verify both sides of the policy:

* Expected dashboard dimensions still populate
* Removed or transformed values no longer appear in Application Insights or Container Apps logs
* Collector logs contain no processor or export errors

## Additional Controls

Collector filtering is one layer of protection. Also consider:

* Removing the trace debug exporter outside troubleshooting windows
* Restricting public ingress or placing an authenticated gateway before the collector
* Limiting Log Analytics and Grafana access with Azure RBAC
* Applying retention requirements to the workspace
* Documenting approved resource attributes and prohibited data classes

## References

* [OpenTelemetry Collector configuration](https://opentelemetry.io/docs/collector/configuration/)
* [Attributes processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/attributesprocessor)
* [Filter processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/filterprocessor)
* [Transform processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/transformprocessor)
