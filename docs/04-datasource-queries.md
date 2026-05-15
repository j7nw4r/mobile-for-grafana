# 04 — Datasource queries

This doc covers the request/response shape of `POST /api/ds/query`, the
per-datasource fields that go inside it, the columnar frame format that
comes back, and the on-device sizing math (`maxDataPoints`, `intervalMs`).

The Grafana web frontend constructs these queries from a complicated
internal model (`SceneQueryRunner`, `getQueryRunner()`, …). We are not
trying to be Grafana's web frontend; we're trying to build the minimum
correct query for each panel-target combination we render.

## Request envelope

```json
POST /api/ds/query
Content-Type: application/json

{
  "from": "1700000000000",
  "to":   "1700003600000",
  "queries": [
    {
      "refId": "A",
      "datasource": { "uid": "abc123", "type": "prometheus" },
      "maxDataPoints": 360,
      "intervalMs": 10000,

      "expr": "rate(http_requests_total[5m])",
      "range": true,
      "instant": false,
      "legendFormat": "{{handler}}"
    }
  ]
}
```

`from` and `to` are top-level — Grafana derives each query's `start` /
`end` / `step` from these. They are Unix-millisecond *strings* (not
numbers), which is a quirk we preserve.

The `queries[]` array can carry queries against multiple datasources in one
request. We don't take advantage of that in v1; we issue one request per
panel, and inside that request all queries share the panel's datasource.

## Response envelope

```json
{
  "results": {
    "A": {
      "frames": [
        {
          "schema": {
            "name": "rate(http_requests_total[5m])",
            "refId": "A",
            "fields": [
              { "name": "Time",  "type": "time" },
              { "name": "Value", "type": "number",
                "labels": { "handler": "/api" } }
            ]
          },
          "data": {
            "values": [
              [1700000000000, 1700000010000, 1700000020000],
              [12.5, 13.1, 12.9]
            ]
          }
        }
      ]
    }
  }
}
```

Three properties of this shape that matter:

1. **Columnar.** Each entry in `values[]` is one *column*, not one row. For
   a 3-sample series with `Time` and `Value` fields, `values` has length 2;
   each inner array has length 3.
2. **One frame per series.** Prometheus query results yield one frame per
   distinct label set. The labels live on the `Value` field's
   `labels` map.
3. **Errors are per-refId.** If query `A` errors but `B` succeeds, the
   response is `{results: {A: {error: "…"}, B: {frames: […]}}}`.

## Frame decoders

Three concrete decoders feed three on-device model types:

```swift
protocol FrameDecoder {
  associatedtype Output
  static func decode(frames: [Frame]) throws -> Output
}

struct TimeSeries {
  let series: [Series]
  struct Series {
    let name: String                    // legend label
    let labels: [String: String]
    let points: [(time: Date, value: Double?)]
    let unit: String?
    let thresholds: Thresholds?
  }
}

struct TableData {
  let columns: [Column]
  struct Column {
    let name: String
    let type: ColumnType                // .time, .number, .string, .bool
    let values: [JSONValue]
  }
  let rowCount: Int
}

struct LogStream {
  let lines: [LogLine]
  struct LogLine {
    let time: Date
    let line: String
    let level: LogLevel?                // parsed from labels
    let labels: [String: String]
  }
}
```

### `TimeSeriesDecoder`

For Prometheus/Loki range queries and any frame whose schema has a `time`
field. Algorithm:

```
for each frame:
  find the time field (type == "time") — typically index 0, but trust the schema
  find the value field(s) (type == "number")
  if value field count > 1: emit one Series per value field, named after the field
  else: emit one Series with name = frame.schema.name, labels = value field's labels
  zip times and values into [(Date, Double?)] (null becomes nil)
```

We treat `nil` value samples as gaps in the series, not zeros — Swift
Charts handles this by skipping the segment. (Grafana's "connect null
values" toggle is in panel options; v1 default is "skip", matching
Grafana's default.)

### `TableDecoder`

For frames without a `time` field, or panels of type `table` regardless of
schema. Straight pass-through:

- Each `FrameField` becomes a `TableData.Column`.
- Column type comes from `FrameField.type` ("time" → render as date,
  "number" → render with unit, "string" → render as-is, "boolean" →
  render as checkmark).

### `LogStreamDecoder`

For Loki query results. Loki's standard frame schema has fields
`{labels, Time, Line, tsNs, id}` — we read the `Time` and `Line` columns
and parse a log level from `labels.level` (Loki's standard) or by
regex-matching the start of `Line` for `INFO`/`WARN`/`ERROR`/`DEBUG`.

## Per-datasource query building

Each target carries datasource-specific fields. The dispatcher reads the
target's `datasource.type` and routes to a builder:

```swift
protocol QueryBuilder {
  static func build(target: Target, panel: Panel,
                    timeRange: ResolvedTimeRange,
                    width: CGFloat,
                    variables: [String: String]) -> [String: JSONValue]
}
```

The builder returns the inner query object (without `from`/`to`/`refId` —
those are added by the caller).

### Prometheus

```swift
enum PrometheusQueryBuilder: QueryBuilder {
  // Reads from target.raw:
  //   expr: String
  //   format: "time_series" | "table" | "heatmap"  (we ignore in v1)
  //   instant: Bool?
  //   range: Bool?
  //   legendFormat: String?
  //   interval: String?      e.g. "30s"
  //   intervalFactor: Int?   not honored in v1
  //
  // Computes:
  //   maxDataPoints: from screen width
  //   intervalMs:    from maxDataPoints and time range
  //   range/instant: default {range: true, instant: false} unless target overrides
  //
  // Substitutes variables into expr (see 06-dashboards-and-variables.md).
}
```

A typical Prometheus query body we emit:

```json
{
  "refId": "A",
  "datasource": {"uid":"…","type":"prometheus"},
  "expr": "rate(http_requests_total{job=\"api\"}[5m])",
  "range": true,
  "instant": false,
  "intervalMs": 30000,
  "maxDataPoints": 360,
  "legendFormat": "{{handler}}"
}
```

### Loki

```swift
enum LokiQueryBuilder: QueryBuilder {
  // Reads from target.raw:
  //   expr: String                 e.g. `{job="grafana"} |= "error"`
  //   queryType: "range" | "instant"   default "range"
  //   maxLines: Int?               default 1000
  //   direction: "BACKWARD" | "FORWARD"  default BACKWARD
  //   step: String?                e.g. "10s"
  //   legendFormat: String?
}
```

A Loki "logs" query (for a logs panel):

```json
{
  "refId": "A",
  "datasource": {"uid":"…","type":"loki"},
  "expr": "{job=\"grafana\",level=\"error\"}",
  "queryType": "range",
  "maxLines": 1000,
  "intervalMs": 30000,
  "maxDataPoints": 360
}
```

A Loki "metric" query (e.g. `sum(rate({job="grafana"}[1m]))`) goes through
`TimeSeriesDecoder` rather than `LogStreamDecoder` — the panel type
decides which decoder runs, not the datasource type.

### TestData

A no-config datasource that Grafana ships with. Useful for development
before we have a real Prometheus to point at.

```json
{
  "refId": "A",
  "datasource": {"uid":"PD8C576611E62080A","type":"testdata"},
  "scenarioId": "random_walk",
  "stringInput": "",
  "intervalMs": 30000,
  "maxDataPoints": 360
}
```

The `scenarioId` we'll use in dev fixtures: `random_walk` (timeseries),
`logs` (logs), `csv_content` (table).

### Future datasources (out of scope v1)

- **CloudWatch / Azure Monitor / Stackdriver** — credential-bearing query
  bodies, complex types. Skipped.
- **Elasticsearch / OpenSearch** — full Elasticsearch query DSL in the
  body. Skipped.
- **InfluxDB** — Flux or InfluxQL, two distinct shapes. Skipped.
- **PostgreSQL / MySQL** — raw SQL in `rawSql`. Skipped (security
  considerations on a phone).

If a panel target hits an unsupported datasource type, we render the panel
shell with an "Unsupported datasource: <type>" body and skip the query.

## Sizing: `maxDataPoints` and `intervalMs`

Grafana's web frontend sizes queries by the panel's pixel width — there's
no point downloading 10,000 points to draw on 360 px. We do the same with
SwiftUI geometry:

```swift
func computeQuerySizing(
  pixelWidth: CGFloat,
  timeRange: ResolvedTimeRange
) -> (maxDataPoints: Int, intervalMs: Int) {

  // One sample every 1 to 2 pixels feels right on phone screens.
  let maxDataPoints = max(50, min(720, Int(pixelWidth.rounded())))

  let durationMs = Int(timeRange.duration * 1000)
  let intervalMs = max(1000, durationMs / maxDataPoints)

  // Snap to the nearest "nice" interval to avoid noisy resolution changes
  // between requests with very similar widths.
  let snapped = snapToNiceInterval(intervalMs)
  return (maxDataPoints, snapped)
}

func snapToNiceInterval(_ ms: Int) -> Int {
  let niceMillis = [
    1_000, 5_000, 10_000, 15_000, 30_000,
    60_000, 5*60_000, 10*60_000, 15*60_000, 30*60_000,
    3_600_000, 6*3_600_000, 12*3_600_000,
    86_400_000, 7*86_400_000
  ]
  return niceMillis.last(where: { $0 <= ms }) ?? 1_000
}
```

`pixelWidth` comes from a `GeometryReader` around the panel. The
sizing recompute happens when the time range or the panel's frame
changes; we don't recompute on every refresh.

## Variable substitution

Before sending the request, we substitute dashboard variables into the
target's `expr` (or `query`). Grafana's syntax:

- `$varname`
- `${varname}`
- `${varname:format}` — formats like `:csv`, `:pipe`, `:regex` for
  multi-value variables

v1 supports the `:csv` and `:pipe` formats (most common in Prometheus
queries); other formats are passed through as the raw multi-value join.
Full grammar lives in
[`06-dashboards-and-variables.md`](06-dashboards-and-variables.md).

## Errors

| Server response | Our behavior |
| --- | --- |
| `results.A.error` set | Show error inline in panel; other refIds still render |
| HTTP 400 | Likely a malformed expr (after substitution); panel shows "Query error" |
| HTTP 401/403 | Bubbled up — credential is bad; auth flow takes over |
| HTTP 502/504 | Panel shows "Datasource timed out" with a retry button |
| Frame schema missing `time` field on a timeseries panel | Treat as empty result, render "No data" |

We do not auto-retry on 5xx in v1. Pull-to-refresh + the panel-level
"Refresh" verb are the user's manual retries.

## Open questions

> Do we treat `intervalMs` derivation as a per-panel concern or a global
> "downsampling budget" for the dashboard?

**Per-panel.** Grafana's web frontend does the same — `panelWidth` is
panel-local, and panels at different widths get different downsampling.
On mobile every panel is full-width so all panels on a dashboard at the
same time range happen to compute the same `intervalMs`, but the *logic*
remains per-panel so when we eventually support multi-column layouts in a
later release nothing has to change.

> Panels with mixed datasources (one target Prometheus, one target Loki) —
> support in v1 or defer?

**Defer.** A panel-level query is one HTTP request to `/api/ds/query` with
N queries inside. The `queries[]` array can hold mixed-datasource queries
(`datasource.uid` is per-query), and Grafana handles them, but our
decoder layer currently picks one decoder per panel based on panel type +
single datasource type. Supporting mixed datasources means decoder
selection becomes per-target, and the panel renderer needs to merge two
series sets that may be at different cadences. Not worth it in v1.

If we encounter a mixed-datasource panel in the wild during testing, we
render the panel shell with a "Multi-datasource panels not supported in
this version" message and skip the query.

---

Onward: [`05-panels-and-charts.md`](05-panels-and-charts.md).
