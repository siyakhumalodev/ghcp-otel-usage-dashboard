---
title: Query and Report on Copilot Telemetry
description: Validate GitHub Copilot OpenTelemetry fields and build custom-agent reports with KQL, Grafana, or Power BI
ms.date: 2026-10-28
ms.topic: how-to
---

## Reporting Flow

The telemetry pipeline does not depend on the reporting tool. The collector
exports telemetry to workspace-based Application Insights, Log Analytics stores
and queries it, and a reporting layer presents governed KQL results.

Use Azure Managed Grafana for operational dashboards with short refresh cycles.
Use Power BI when the report must join telemetry with organizational, financial,
or adoption data and requires a reusable semantic model.

## Validate the Source Data

Do not build a report from query syntax alone. GitHub Copilot and VS Code versions
can change span names and resource attributes. Validate the source table, field
coverage, and totals with controlled agent invocations.

1. Select a recent time range that contains known custom-agent activity.
2. Confirm that exported events appear in the `dependencies` table.
3. Inspect recent dimensions instead of assuming attribute names.
4. Run a controlled agent invocation and compare it with the resulting trace.
5. Measure coverage for agent, session, identity, repository, and token fields.
6. Save the approved query with its purpose, owner, audience, and time window.

List the dimensions present in a recent sample:

```kusto
dependencies
| where timestamp > ago(24h)
| take 200
| extend dims = todynamic(customDimensions)
| mv-expand key = bag_keys(dims)
| summarize records = count() by attribute = tostring(key)
| order by records desc
```

Inspect records from a known custom agent:

```kusto
let probeAgent = "<agent-name>";
dependencies
| where timestamp > ago(24h)
| extend dims = todynamic(customDimensions)
| extend agent = coalesce(
    tostring(dims["copilot_chat.mode_name"]),
    tostring(dims["agent.name"]),
    tostring(dims["gen_ai.agent.name"]))
| where agent == probeAgent
| extend session = coalesce(
    tostring(dims["session.id"]),
    tostring(dims["copilot_chat.session_id"]),
    tostring(dims["gen_ai.conversation.id"]))
| project timestamp, agent, session, traceId = operation_Id, spanId = id,
    spanName = name, duration, success, resultCode, customDimensions
| order by timestamp desc
| take 100
```

## Capture Identity Only When Approved

The user and repository dimensions can identify people, teams, and projects.
Enable identity capture only for an approved reporting purpose with documented
access, retention, and data-minimization controls.

Add `captureIdentity` to the existing VS Code settings when identity reporting is
approved:

```json
{
  "github.copilot.chat.otel.enabled": true,
  "github.copilot.chat.otel.exporterType": "otlp-http",
  "github.copilot.chat.otel.otlpEndpoint": "https://<container-app-fqdn>",
  "github.copilot.chat.otel.captureIdentity": true
}
```

Restart VS Code and emit fresh telemetry. Enabling identity capture does not
backfill identity fields in existing records. Consider pseudonymization or an
approved user-to-team mapping before distributing identity-level reports.

## Query Token Usage

The following query reports input and output tokens by agent, user, and
repository. Missing token attributes contribute zero, which does not prove that
no tokens were consumed. Measure token-field coverage before using totals for
chargeback or adoption reporting.

```kusto
dependencies
| where name contains "invoke_agent"
| extend dims = todynamic(customDimensions)
| extend agent_name = coalesce(
    tostring(dims["copilot_chat.mode_name"]),
    tostring(dims["agent.name"]),
    tostring(dims["gen_ai.agent.name"]))
| where isnotempty(agent_name)
| extend github_username = coalesce(tostring(dims["user.name"]), "-"),
         repository_url = coalesce(
             tostring(dims["github.copilot.git.repository"]),
             tostring(dims["copilot_chat.repo.remote_url"]))
| extend repository_name = coalesce(
    extract(@"([^/:]+?)(?:\.git)?/?$", 1, repository_url),
    "Unknown")
| extend input_tokens = coalesce(
             tolong(dims["gen_ai.usage.input_tokens"]), tolong(0)),
         output_tokens = coalesce(
             tolong(dims["gen_ai.usage.output_tokens"]), tolong(0))
| summarize total_tokens = sum(input_tokens + output_tokens)
    by agent_name, github_username, repository_name
| order by total_tokens desc
```

Use this result for a table, bar chart, or donut chart. A row represents an
agent, user, and repository combination, not an agent-only total.

## Query Custom-Agent Usage

Use a separate query for invocation and session counts. This version excludes
empty session IDs from the approximate distinct count.

```kusto
dependencies
| extend dims = todynamic(customDimensions)
| where tostring(dims["github.copilot.agent.type"]) =~ "custom"
| extend agent = coalesce(
    tostring(dims["copilot_chat.mode_name"]),
    tostring(dims["agent.name"]),
    tostring(dims["gen_ai.agent.name"])),
    session = coalesce(
    tostring(dims["session.id"]),
    tostring(dims["copilot_chat.session_id"]),
    tostring(dims["gen_ai.conversation.id"])),
    username = coalesce(tostring(dims["user.name"]), "-"),
    repository_url = coalesce(
    tostring(dims["github.copilot.git.repository"]),
    tostring(dims["copilot_chat.repo.remote_url"]))
| where isnotempty(agent)
| extend repository = coalesce(
    extract(@"([^/:]+?)(?:\.git)?/?$", 1, repository_url),
    "Unknown")
| summarize
    Invocations = count(),
    Sessions = dcountif(session, isnotempty(session)),
    LastUsed = max(timestamp)
    by agent, username, repository
| project
    ['Agent Name'] = agent,
    Username = username,
    Repository = repository,
    Invocations,
    Sessions,
    LastUsed
| order by Invocations desc
```

`dcountif` is approximate. Report session counts only after checking session-field
coverage and confirming that dependency records represent the invocations you
intend to measure.

## Query Invocation Trends

Use a time-binned query for a trend panel. Adjust the bin size to the dashboard
time range and expected event volume.

```kusto
dependencies
| extend dims = todynamic(customDimensions)
| where tostring(dims["github.copilot.agent.type"]) =~ "custom"
| extend agent = coalesce(
    tostring(dims["copilot_chat.mode_name"]),
    tostring(dims["agent.name"]),
    tostring(dims["gen_ai.agent.name"]))
| where isnotempty(agent)
| summarize Invocations = count() by bin(timestamp, 1h), agent
| order by timestamp asc
```

## Build the Grafana View

Use the Azure Monitor data source with an identity that has read access to the
workspace.

1. Add a collapsible **Custom agents** row.
2. Add a table for agent, user, repository, invocations, sessions, and last use.
3. Add a time-series panel with one series per agent or a controlled top-N.
4. Add token usage only after validating token-field coverage and totals.
5. Add agent, user, repository, and environment variables where the audience is
   approved to see those dimensions.
6. Bound the time window, cap result size, and set a deliberate refresh interval.
7. Test query performance and permissions with the same identity used at runtime.

Prefer a top-N with drill-down over a chart containing every agent. Keep token
usage separate from invocation counts because one cannot be inferred from the
other.

## Build a Power BI Alternative

Power BI can report on the same governed KQL output without changing the
collector pipeline.

1. Aggregate raw events in KQL and return only approved columns.
2. Use Import mode for routine management reporting.
3. Create usage and daily-trend fact tables with Date, Agent, Repository, and
   approved User or Team dimensions.
4. Define separate measures for tokens, invocations, sessions, repositories, and
   missing identifiers.
5. Include a datetime column and configure incremental refresh.
6. Apply workspace roles, semantic-model permissions, and row-level security as
   required.
7. Use Event Hubs and Microsoft Fabric Real-Time Intelligence only when scale or
   latency requirements justify another platform component.

Power BI is a better fit when telemetry must join governed business data or use a
shared semantic model. Grafana is a better fit for telemetry-led operations, KQL
troubleshooting, and shorter refresh cycles.

## Monitor Data Quality

Track reporting quality alongside usage:

* Percentage of records with an agent name
* Percentage of records with a session ID
* Percentage of agent records with token attributes
* Percentage of records with approved identity and repository dimensions
* Query duration, failures, and result truncation
* Ingestion delay between the controlled event and the report

Use explicit `Unknown` or `-` values rather than silently discarding incomplete
records. Explain those placeholders in the report so missing dimensions are not
misinterpreted as real identities or repositories.

## References

* [Integrate Log Analytics with Power BI](https://learn.microsoft.com/azure/azure-monitor/logs/log-powerbi)
* [Use Azure Data Explorer data in Power BI](https://learn.microsoft.com/azure/data-explorer/power-bi-data-connector)
* [Microsoft Fabric Real-Time Intelligence](https://learn.microsoft.com/fabric/real-time-intelligence/)
