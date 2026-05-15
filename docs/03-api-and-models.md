# 03 — API surface + Swift models

This doc catalogs every Grafana HTTP endpoint the app calls and the Swift
Codable types each request/response maps to. It is the contract surface
between `Networking/` and the rest of the app.

Endpoints below are documented against **Grafana 10.x and 11.x**. Where the
two versions diverge we note both.

## Versioning + feature detection

We probe the Grafana version once per session:

```
GET /api/health
→ 200 {"commit":"…","database":"ok","version":"11.2.0"}
```

We parse the `version` string into a `(major, minor, patch)` tuple and use
it to:

- Choose between `folderIds` (≤9.x) and `folderUIDs` (10.x+) on `/api/search`
  (we only support 10+ so this is a safety guard; if version < 10 we show
  "Unsupported Grafana version (10.0 or later required)" and abort).
- Decide if unified alerting endpoints are available (always true on
  supported versions).

## Endpoint catalog

Grouped by feature area. Every endpoint here lands in some phase of
[`11-roadmap.md`](11-roadmap.md).

### Auth / identity

| Method | Path | Returns | Notes |
| --- | --- | --- | --- |
| `POST` | `/api/login` | `{message:"Logged in"}` + `Set-Cookie: grafana_session=…` | Basic-auth login. Body `{user, password}`. |
| `POST` | `/api/logout` | 200 | Best-effort. |
| `GET`  | `/api/user` | `User` | Validates current credential. |
| `GET`  | `/api/health` | `{commit,database,version}` | Version probe. |
| `GET`  | `/api/frontend/settings` | `FrontendSettings` | Used to discover OAuth providers. |

### Folders / dashboards / search

| Method | Path | Returns | Notes |
| --- | --- | --- | --- |
| `GET`  | `/api/folders` | `[Folder]` | Top-level folders. Nested folders need v11+. |
| `GET`  | `/api/search?query=&type=dash-db&starred=&folderUIDs=&tag=&limit=` | `[SearchHit]` | The main browse + search endpoint. |
| `GET`  | `/api/dashboards/uid/{uid}` | `DashboardEnvelope` | The dashboard itself. |
| `POST` | `/api/user/stars/dashboard/uid/{uid}` | 200 | Star a dashboard. |
| `DELETE` | `/api/user/stars/dashboard/uid/{uid}` | 200 | Unstar a dashboard. |

### Datasources + queries

| Method | Path | Returns | Notes |
| --- | --- | --- | --- |
| `GET`  | `/api/datasources/uid/{uid}` | `Datasource` | Resolve a target's datasource. |
| `POST` | `/api/ds/query` | `QueryResponse` | The workhorse — see `04-datasource-queries.md`. |

### Alerts + silences

| Method | Path | Returns | Notes |
| --- | --- | --- | --- |
| `GET`  | `/api/prometheus/grafana/api/v1/alerts` | `{data:{alerts:[AlertInstance]}}` | Firing + pending instances. |
| `GET`  | `/api/prometheus/grafana/api/v1/rules` | `{data:{groups:[AlertRuleGroup]}}` | Rule definitions with current alert state. |
| `GET`  | `/api/alertmanager/grafana/api/v2/alerts` | `[AmAlert]` | Pipeline view — includes silenced/inhibited. |
| `GET`  | `/api/alertmanager/grafana/api/v2/silences` | `[Silence]` | Active silences. |
| `POST` | `/api/alertmanager/grafana/api/v2/silences` | `{silenceID}` | Create a silence. |
| `DELETE` | `/api/alertmanager/grafana/api/v2/silence/{id}` | 200 | Expire a silence. |

### Annotations

| Method | Path | Returns | Notes |
| --- | --- | --- | --- |
| `GET`  | `/api/annotations?dashboardUID=&panelId=&from=&to=&limit=` | `[Annotation]` | We do not create or delete in v1. |

## Swift models

These are sketches, not final code. The implementation in `Models/` will
follow these shapes; trivial fields (`description?` on every type) are
elided.

### Common scalars

```swift
typealias UID = String

struct UnixMilli: Codable, Hashable {
  let raw: Int64
  var date: Date { Date(timeIntervalSince1970: Double(raw) / 1000) }
}
```

`UnixMilli` exists because Grafana emits time-as-millisecond-since-epoch in
most contexts (`/api/ds/query`, `/api/annotations`). Wrapping it makes the
decode-site type tell the reader "this is ms, not seconds".

### `User`

```swift
struct User: Codable {
  let id: Int
  let email: String
  let name: String
  let login: String
  let isGrafanaAdmin: Bool
  let orgId: Int
}
```

From `GET /api/user`.

### `Folder`

```swift
struct Folder: Codable, Identifiable {
  let id: Int                  // numeric, legacy
  let uid: UID                 // primary key we use
  let title: String
  let parentUid: UID?          // v11+ for nested folders
}
```

From `GET /api/folders`. We sort client-side by `title`.

### `SearchHit`

```swift
struct SearchHit: Codable, Identifiable {
  enum Kind: String, Codable {
    case dashboard = "dash-db"
    case folder    = "dash-folder"
  }
  let id: Int                  // legacy
  let uid: UID
  let title: String
  let type: Kind
  let url: String              // /d/{uid}/{slug}
  let folderUid: UID?
  let folderTitle: String?
  let tags: [String]
  let isStarred: Bool?
  let sortMeta: Int?
}
```

From `GET /api/search`. `type` discriminates folder rows from dashboard
rows. We always pass `type=dash-db` when we want dashboards only.

### `DashboardEnvelope`

```swift
struct DashboardEnvelope: Codable {
  let dashboard: DashboardJSON
  let meta: DashboardMeta
}

struct DashboardMeta: Codable {
  let isStarred: Bool
  let folderUid: UID?
  let folderTitle: String?
  let canSave: Bool
  let canEdit: Bool
  let canAdmin: Bool
  let url: String              // /d/{uid}/{slug}
  let updated: String          // ISO-8601 string
  let version: Int
}
```

From `GET /api/dashboards/uid/{uid}`.

### `DashboardJSON`

This is the heart of the schema. We do *not* try to model every Grafana
dashboard field — we model the subset we need to render. Unknown fields are
ignored at decode time.

```swift
struct DashboardJSON: Codable {
  let uid: UID
  let title: String
  let tags: [String]?
  let timezone: String?               // "" or "browser" or IANA name
  let time: TimeRange                 // dashboard default time range
  let refresh: String?                // "30s" / "1m" / "" — we ignore in v1
  let templating: Templating?
  let panels: [Panel]
  let annotations: AnnotationDefs?
}

struct TimeRange: Codable {
  let from: String                    // "now-6h" or "1700000000000"
  let to: String                      // "now" or "1700001000000"
}

struct Templating: Codable {
  let list: [Variable]
}

struct Variable: Codable {
  enum Kind: String, Codable {
    case query, custom, constant
    case interval, datasource, textbox, adhoc   // parsed but unsupported in v1
  }
  let name: String                    // identifier used in `$name` / `${name}` substitution
  let type: Kind
  let label: String?                  // display label; falls back to `name`
  let description: String?
  let hide: Int?                      // 0 = show, 1 = hide label, 2 = hide variable
  let datasource: DatasourceRef?      // present on `query` type
  let query: JSONValue?               // String for most, object for some Prometheus shapes
  let regex: String?                  // optional filter applied to options
  let multi: Bool?
  let includeAll: Bool?
  let allValue: String?               // value to substitute when "All" is picked
  let current: VariableSelection?     // currently-selected option(s)
  let options: [VariableOption]?      // available choices (custom: from query string; query: from datasource)
}

struct VariableSelection: Codable {
  // For multi-value variables Grafana emits arrays for text/value;
  // for single-value variables it emits strings. We decode both.
  let text: JSONValue?                // String or [String]
  let value: JSONValue?               // String or [String]
  let selected: Bool?
}

struct VariableOption: Codable {
  let text: String
  let value: String
  let selected: Bool
}

struct AnnotationDefs: Codable {
  let list: [AnnotationDef]
}

struct AnnotationDef: Codable {
  let name: String
  let enable: Bool
  let datasource: DatasourceRef?
  let iconColor: String?
}
```

### `Panel`

```swift
struct Panel: Codable, Identifiable {
  let id: Int
  let type: String                    // "timeseries", "stat", "gauge", ...
  let title: String?
  let gridPos: GridPos
  let datasource: DatasourceRef?      // panel-level default
  let targets: [Target]?
  let fieldConfig: FieldConfig?
  let options: JSONValue?             // type-specific, kept opaque
}

struct GridPos: Codable {
  let x: Int                          // 0..23
  let y: Int
  let w: Int                          // width in grid columns
  let h: Int                          // height in grid rows (1 row ≈ 30px on web)
}

struct DatasourceRef: Codable {
  let uid: UID?                       // canonical reference
  let type: String?                   // "prometheus", "loki", …
  // Legacy dashboards sometimes use a string here; we handle both.
}
```

We collapse the 24-column grid to a single column on mobile (see
[`06-dashboards-and-variables.md`](06-dashboards-and-variables.md)). So
`x` and `w` are read but not used; only `y` (for ordering) and `h` (for
min-height hint).

### `Target`

```swift
struct Target: Codable {
  let refId: String                   // "A", "B", "C", ...
  let datasource: DatasourceRef?
  let hide: Bool?
  // Per-datasource fields decoded out-of-band — see DataSources/.
  // We keep the raw JSON to hand off to the datasource builder.
  let raw: JSONValue
}
```

The trick here is that `Target` carries arbitrary datasource-specific fields
(`expr` for Prometheus, `query` for Loki, etc). We decode the common
envelope as `Target` and keep the entire JSON object as `raw`; the
`DataSources/` layer then re-decodes `raw` into the appropriate concrete
type for the actual datasource type.

### `FieldConfig`

```swift
struct FieldConfig: Codable {
  let defaults: FieldDefaults
  let overrides: [FieldOverride]?     // v1: parsed but not applied
}

struct FieldDefaults: Codable {
  let unit: String?                   // "bytes", "percent", "short", ...
  let decimals: Int?
  let min: Double?
  let max: Double?
  let mappings: [ValueMapping]?       // v1: stat panels only
  let thresholds: Thresholds?
  let color: ColorConfig?
}

struct Thresholds: Codable {
  let mode: String                    // "absolute" or "percentage"
  let steps: [ThresholdStep]
}

struct ThresholdStep: Codable {
  let color: String                   // "green", "red", "#abcdef"
  let value: Double?                  // nil = -∞ (the base)
}
```

### `Datasource`

```swift
struct Datasource: Codable {
  let id: Int
  let uid: UID
  let name: String
  let type: String                    // "prometheus", "loki", "testdata", ...
  let url: String
  let isDefault: Bool
}
```

We cache datasource lookups by UID for the lifetime of a `ServerContext`.

### `QueryResponse`

```swift
struct QueryResponse: Codable {
  let results: [String: QueryResult]   // keyed by refId
}

struct QueryResult: Codable {
  let frames: [Frame]?
  let error: String?
  let status: Int?
}

struct Frame: Codable {
  let schema: FrameSchema
  let data: FrameData
}

struct FrameSchema: Codable {
  let name: String?
  let refId: String?
  let fields: [FrameField]
}

struct FrameField: Codable {
  let name: String
  let type: String          // "time", "number", "string", "boolean", "other"
  let typeInfo: TypeInfo?
  let labels: [String: String]?       // for Prometheus series labels
  let config: FieldDefaults?
}

struct FrameData: Codable {
  // Columnar: values[fieldIndex][rowIndex]
  // Each column has the type the schema says it does. JSON numbers; we
  // decode lazily because most fields are strings or doubles.
  let values: [[JSONValue]]
}
```

Frame decoding is its own thing — see
[`04-datasource-queries.md`](04-datasource-queries.md).

### `JSONValue`

Generic Codable enum for "we don't know the shape, hold onto it":

```swift
enum JSONValue: Codable {
  case null
  case bool(Bool)
  case number(Double)
  case integer(Int64)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}
```

Used in three places: `Target.raw` (datasource-specific target body),
`Panel.options` (panel-type-specific options), and `FrameData.values`
(needs to hold any cell type). Implementation is the standard "try each
case" decode pattern.

### Alerts

```swift
struct AlertInstance: Codable {
  let labels: [String: String]        // alertname, instance, severity, …
  let annotations: [String: String]
  let state: String                   // "firing", "pending", "inactive"
  let activeAt: String?               // ISO-8601
  let value: String?                  // last sample
}

struct AlertRuleGroup: Codable {
  let name: String
  let file: String
  let rules: [AlertRule]
  let interval: Int
}

struct AlertRule: Codable {
  let name: String
  let query: String
  let duration: Int                   // seconds; the "for"
  let labels: [String: String]?
  let annotations: [String: String]?
  let state: String                   // "firing"/"pending"/"inactive"
  let alerts: [AlertInstance]?        // instances under this rule
  let health: String                  // "ok"/"err"/"nodata"
  let type: String                    // "alerting" or "recording"
}

struct AmAlert: Codable {
  let labels: [String: String]
  let annotations: [String: String]
  let startsAt: String
  let endsAt: String
  let updatedAt: String
  let status: AmAlertStatus
}

struct AmAlertStatus: Codable {
  let state: String                   // "active", "suppressed", "unprocessed"
  let silencedBy: [String]?
  let inhibitedBy: [String]?
}

struct Silence: Codable {
  let id: String
  let matchers: [Matcher]
  let startsAt: String
  let endsAt: String
  let createdBy: String
  let comment: String
  let status: SilenceStatus
}

struct Matcher: Codable {
  let name: String
  let value: String
  let isRegex: Bool
  let isEqual: Bool                   // default true; false = "not equal"
}

struct SilenceStatus: Codable {
  let state: String                   // "active", "expired", "pending"
}
```

### Annotations

```swift
struct Annotation: Codable, Identifiable {
  let id: Int
  let alertId: Int?
  let dashboardUID: UID?
  let panelId: Int?
  let time: Int64                     // unix ms
  let timeEnd: Int64?                 // unix ms; equals `time` for point
  let text: String
  let tags: [String]
  let type: String                    // "alert" or "annotation"
}
```

### `FrontendSettings` (only the slice we need)

```swift
struct FrontendSettings: Codable {
  let oauth: [String: OAuthProvider]?
  let authProxyEnabled: Bool?
  let ldapEnabled: Bool?
}

struct OAuthProvider: Codable {
  let name: String                    // display name
  let icon: String?                   // grafana's icon hint
}
```

Used by the SSO flow to populate the provider picker (see
[`02-auth.md`](02-auth.md)).

## Error mapping

```swift
enum GrafanaError: Error, CustomStringConvertible {
  case unreachable(host: String, underlying: URLError?)
  case unauthorized(message: String?)              // 401
  case forbidden(message: String?)                 // 403
  case notFound(message: String?)                  // 404
  case unprocessable(message: String?)             // 422 (silence shape errors)
  case rateLimited(retryAfter: TimeInterval?)      // 429
  case serverError(status: Int, message: String?)  // 5xx
  case decode(underlying: DecodingError)
  case unexpected(status: Int, body: String?)
}
```

Grafana's standard error envelope is:

```json
{"message": "Unauthorized", "traceID": "abc123"}
```

`GrafanaClient` decodes the body opportunistically — if the body parses as
this shape we use `message`; otherwise we pass the body as a string into the
`unexpected` case.

## Date handling

Three formats in the wild:

| Format | Where it appears | Decode strategy |
| --- | --- | --- |
| Unix ms (Int64) | `/api/ds/query` frames, `/api/annotations` | `UnixMilli` type |
| ISO-8601 string | Alert `activeAt`, dashboard `meta.updated`, silence `startsAt`/`endsAt` | `ISO8601DateFormatter` with fractional seconds |
| Grafana relative (`now-6h`) | Dashboard `time.from`/`to`, time-range picker | Parsed in `Models/TimeRangeParser.swift`; not a `Date` |

The third one is unique to Grafana: `now`, `now/d` (now rounded down to
day), `now-1h`, `now-7d/d`. We handle:

- `now`, `now-<N><unit>`, `now+<N><unit>` where unit ∈ `s m h d w M y`
- Optional trailing `/<unit>` for rounding (`now/d` = start of today)

At query time we resolve to a `Date` against the current clock. We do
*not* resolve at dashboard-load time, because the user expects "last 6
hours" to keep meaning "last 6 hours" as the clock advances.

## Decoding policy

- `JSONDecoder().keyDecodingStrategy = .useDefaultKeys` (Grafana uses
  camelCase already; not converting).
- `dateDecodingStrategy` — we do *not* set one globally; the model types
  pick the right strategy per field via `UnixMilli` wrapper or manual
  `init(from:)`.
- Unknown fields: ignored (default Codable behavior).
- Missing fields on optional members: `nil`.
- Missing fields on required members: decode error → surfaced to the user
  as "Unexpected response from Grafana" with a "Copy diagnostics" button.

## Tests

`GrafanaViewerTests/Models/` contains one test file per model with:

- A "happy path" JSON fixture from a stock Grafana 11.x
- A "minimal" JSON fixture (only required fields)
- A "weird optional" fixture (e.g. `gridPos` missing — which the Grafana
  schema technically allows for some panel types)

Fixtures live under `GrafanaViewerTests/Fixtures/<endpoint>.json`. They are
captured from a real Grafana once, then committed.

---

Onward: [`04-datasource-queries.md`](04-datasource-queries.md).
