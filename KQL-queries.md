---
title: Copilot Agent KQL Query Reference
description: Copy-ready queries for agent sessions, custom-agent usage, tokens, traces, and telemetry dimensions.
---

## KQL Query Reference

Explore GitHub Copilot telemetry using the Application Insights `dependencies`
schema. Each query includes its expected output, time range, and limitations.

## Before You Run

* Run each query separately, using only the contents of its KQL code block.
* Confirm that the selected query source exposes `dependencies` and its columns.
* Queries with `ago(24h)` restrict results to the last 24 hours. Queries without
  an explicit time filter use the query tool's selected time range. Check that
  range before running a query.
* Timestamps are UTC; dependency durations are in milliseconds.

> [!IMPORTANT]
> Invocation counts below count dependency records, not independently verified
> user actions. Validate telemetry coverage and record semantics before using
> the results as usage measures.

## Query Index

* [Agent sessions](#agent-sessions)
* [All custom agents](#all-custom-agents)
* [Custom agent invocations by session](#custom-agent-invocations-by-session)
* [OTel custom agent trace probe](#otel-custom-agent-trace-probe)
* [Client location sample](#client-location-sample)
* [Custom dimension inventory](#custom-dimension-inventory)
* [Token usage by agent, username, and repository](#token-usage-by-agent-username-and-repository)
* [Custom agent usage by username and repository](#custom-agent-usage-by-username-and-repository)
* [Identity and governance](#identity-and-governance)
* [HTML source notes](#html-source-notes)

## Agent Sessions

Returns one row per session/agent pair for `invoke_agent` operations with both
identifiers present, ordered by `invocations` descending.

* Output columns: `session`, `agent`, `invocations`
* Time range: query tool selection; no explicit query filter

```kusto
dependencies
| extend dims = todynamic(customDimensions)
| extend op = coalesce(tostring(dims["gen_ai.operation.name"]), name)
| where op has "invoke_agent"
| extend agent = coalesce(tostring(dims["copilot_chat.mode_name"]), tostring(dims["agent.name"]))
| extend session  = coalesce(tostring(dims["session.id"]), tostring(dims["gen_ai.conversation.id"]))
| where isnotempty(agent) and isnotempty(session)
| summarize invocations=count() by session, agent
| order by invocations desc
```

## All Custom Agents

Returns one row per named custom agent, ordered by `invocations` descending.
`sessions` is an approximate distinct count; `lastUsed` is the latest timestamp.

* Output columns: `agent`, `invocations`, `sessions`, `lastUsed`
* Time range: last 24 hours

> [!NOTE]
> Empty session IDs can count as a distinct value. Check session-field coverage
> before interpreting `sessions`.

```kusto
dependencies
| where timestamp > ago(24h)
| extend dims = todynamic(customDimensions)
| where tostring(dims["github.copilot.agent.type"]) =~ "custom"
| extend agent = coalesce(tostring(dims["copilot_chat.mode_name"]), tostring(dims["agent.name"]), tostring(dims["gen_ai.agent.name"]))
| extend session = coalesce(tostring(dims["session.id"]), tostring(dims["copilot_chat.session_id"]), tostring(dims["gen_ai.conversation.id"]))
| where isnotempty(agent)
| summarize invocations=count(), sessions=dcount(session), lastUsed=max(timestamp) by agent
| order by invocations desc
```

## Custom Agent Invocations by Session

Returns one row per custom agent/session pair, ordered by `lastUsed` descending.
Rows missing either identifier are excluded.

* Output columns: `agent`, `session`, `invocations`, `firstUsed`, `lastUsed`, `totalDuration`
* Time range: last 24 hours

`totalDuration` sums dependency durations in milliseconds. Durations can overlap,
so this total does not necessarily represent elapsed session time.

```kusto
dependencies
| where timestamp > ago(24h)
| extend dims = todynamic(customDimensions)
| where tostring(dims["github.copilot.agent.type"]) =~ "custom"
| extend agent = coalesce(tostring(dims["copilot_chat.mode_name"]), tostring(dims["agent.name"]), tostring(dims["gen_ai.agent.name"]))
| extend session = coalesce(tostring(dims["session.id"]), tostring(dims["copilot_chat.session_id"]), tostring(dims["gen_ai.conversation.id"]))
| where isnotempty(agent) and isnotempty(session)
| summarize invocations=count(), firstUsed=min(timestamp), lastUsed=max(timestamp), totalDuration=sum(duration) by agent, session
| order by lastUsed desc
```

## OTel Custom Agent Trace Probe

Returns up to 100 of the most recent dependency records for `probeAgent`.
`agentAttribute` identifies the field used to resolve the agent name.

* Output columns: `timestamp`, `agent`, `agentAttribute`, `session`, `traceId`,
  `spanId`, `spanName`, `duration`, `success`, `resultCode`
* Time range: last 24 hours

Change `probeAgent` to inspect another agent. No custom-agent type filter is
applied. `duration` is in milliseconds.

```kusto
let probeAgent = "OTel Trace Probe";
dependencies
| where timestamp > ago(24h)
| extend dims = todynamic(customDimensions)
| extend agentFromMode = tostring(dims["copilot_chat.mode_name"])
| extend agentFromSpan = tostring(dims["agent.name"])
| extend agent = coalesce(agentFromMode, agentFromSpan)
| where agent == probeAgent
| extend session = coalesce(tostring(dims["session.id"]), tostring(dims["gen_ai.conversation.id"]))
| extend agentAttribute = case(isnotempty(agentFromMode), "copilot_chat.mode_name", isnotempty(agentFromSpan), "agent.name", "unknown")
| project timestamp, agent, agentAttribute, session, traceId=operation_Id, spanId=id, spanName=name, duration, success, resultCode
| order by timestamp desc
| take 100
```

## Client Location Sample

Returns an unordered sample of up to 50 dependency records, not the latest
50 records or country totals.

* Output columns: `timestamp`, `client_CountryOrRegion`, `client_StateOrProvince`,
  `client_City`, `client_IP`
* Time range: last 24 hours

Location and IP fields may be empty or masked and may reflect collector egress
rather than the developer's location.

```kusto
dependencies
| where timestamp > ago(24h)
| project timestamp, client_CountryOrRegion, client_StateOrProvince, client_City, client_IP
| take 50
```

## Custom Dimension Inventory

Returns custom-dimension key names and the number of sampled records containing
each key, ordered by `hits` descending. Inspects an unordered sample of up to
200 dependencies, not all records.

* Output columns: `key`, `hits`
* Time range: last 24 hours

```kusto
dependencies
| where timestamp > ago(24h)
| take 200
| extend dims = todynamic(customDimensions)
| mv-expand k = bag_keys(dims)
| summarize hits=count() by key=tostring(k)
| order by hits desc
```

## Token Usage by Agent, Username, and Repository

Returns one row per agent/user/repository combination, ordered by `total_tokens`
descending. `total_tokens` sums input and output tokens on `invoke_agent` spans.

* Output columns: `agent_name`, `github_username`, `repository_name`, `total_tokens`
* Time range: query tool selection; no explicit query filter
* Source: HTML starting KQL example and Grafana donut panel (the same query)

Missing usernames display as `-`, missing repositories as `Unknown`, and missing
token values contribute zero. Each donut slice represents an agent/user/repository
combination, not an agent-only aggregation.

> [!IMPORTANT]
> Zero does not prove that no tokens were consumed. Validate token coverage on
> these spans. Despite the HTML's custom-agent heading, this query does not
> filter agent type to custom.

```kusto
dependencies
| where name contains "invoke_agent"
| extend dims = todynamic(customDimensions)
| extend agent_name = coalesce(
    tostring(dims["copilot_chat.mode_name"]),
    tostring(dims["agent.name"]))
| where isnotempty(agent_name)
| extend github_username = coalesce(tostring(dims["user.name"]), "-"),
         repository_url = coalesce(
             tostring(dims["github.copilot.git.repository"]),
             tostring(dims["copilot_chat.repo.remote_url"]))
| extend repository_name = coalesce(
    extract(@"([^/:]+?)(?:\.git)?/?$", 1, repository_url),
    "Unknown")
| extend input_tokens = coalesce(tolong(dims["gen_ai.usage.input_tokens"]), tolong(0)),
         output_tokens = coalesce(tolong(dims["gen_ai.usage.output_tokens"]), tolong(0))
| summarize total_tokens = sum(input_tokens + output_tokens)
    by agent_name, github_username, repository_name
| order by total_tokens desc
```

## Custom Agent Usage by Username and Repository

Returns one row per custom agent/user/repository combination, ordered by
`Invocations` descending. Suitable for a Grafana Table panel or Power BI import.

* Output columns: `Agent Name`, `Username`, `Repository`, `Invocations`, `Sessions`, `LastUsed`
* Time range: query tool selection; no explicit query filter
* Source: HTML custom agent usage table

`Invocations` counts custom-agent dependency records; `Sessions` is an approximate
distinct session count; `LastUsed` is the latest timestamp. Missing usernames
display as `-` and missing repositories as `Unknown`.

> [!NOTE]
> Empty session IDs can count as a distinct value. This query does not restrict
> records to `invoke_agent` spans. Validate the counts against the intended
> usage measure.

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
    Sessions = dcount(session),
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

## Identity and Governance

Username reporting requires approved identity capture, including the VS Code
setting `"github.copilot.chat.otel.captureIdentity": true` described in the HTML.
Enabling this setting does not backfill previously emitted records.

User and repository identifiers require an approved reporting purpose,
restricted access, and appropriate retention. Consider pseudonymisation or an
approved user/team mapping for wider reporting.

## HTML Source Notes

The supplied observability leave-behind includes two distinct KQL queries,
retained above. Its repeated token query appears only once here. Its VS Code
settings JSON is configuration, not a KQL query.

The HTML mentions a time-binned companion query but does not supply its KQL.
