# 06 — Dashboards, variables, time range

This doc covers everything between "the user picked a dashboard" and "the
panels are issuing queries": folder browsing, mobile-friendly grid layout,
the time range picker, and variable resolution.

## Folder browsing

Endpoint: `GET /api/folders`.

```json
[
  {"id":1,"uid":"prod","title":"Production","parentUid":null},
  {"id":2,"uid":"stage","title":"Staging","parentUid":null}
]
```

We render the home tab as two stacked sections (in priority order):

```
┌────────────────────────────────────────┐
│  ★ Starred                             │
│  ─────────────────────────────────     │
│  • API request rate                    │
│  • Cluster health                      │
│                                        │
│  📁 Folders                            │
│  ─────────────────────────────────     │
│  > Production                          │
│  > Staging                             │
│                                        │
│  📊 Recent                             │
│  ─────────────────────────────────     │
│  • Disk usage (Production)             │
│  • Pod restarts (Staging)              │
└────────────────────────────────────────┘
```

Folder tap → push a list of that folder's dashboards (`GET /api/search`
with `folderUIDs=<uid>&type=dash-db`).

### Nested folders (v11)

Grafana 11 introduced nested folders. `Folder.parentUid` distinguishes
top-level from nested. v1 supports two levels deep (top-level + one
level of nesting). Deeper nesting renders as flat under the second
level, with a "show in Grafana" note.

### "All dashboards" mode

If a server has no folders (or very few), the folder section is replaced
by a flat dashboards list. We detect this when `GET /api/folders` returns
fewer than 2 items.

## Dashboard list (within a folder)

```
┌────────────────────────────────────────┐
│  ← Production                          │
│  ─────────────────────────────────     │
│  [ search this folder...            ]  │
│                                        │
│  • API request rate                    │
│    tags: api, latency                  │
│  • Cluster health                      │
│    tags: kubernetes                    │
│  • Disk usage                          │
└────────────────────────────────────────┘
```

Local search-within-folder is client-side filtering of the already-loaded
list (no extra API call). Tags display under the title in a smaller
muted font.

## Dashboard detail

Endpoint: `GET /api/dashboards/uid/{uid}` returns `DashboardEnvelope`.

Render order:

1. Title (centered, large).
2. Toolbar (time range picker, variable bar, refresh, star).
3. Panel list (vertically scrolling).

```
┌────────────────────────────────────────┐
│  ← API request rate              ★    │
│  [now-6h ▾]  [Refresh ↻]               │
│                                        │
│  Variable: env   [production ▾]        │
│  Variable: cluster [us-east-1 ▾]       │
│  ──────────────────────────────────    │
│                                        │
│  ┌──────────────────────────────────┐  │
│  │ Request rate by handler          │  │
│  │                                  │  │
│  │  [timeseries chart here]         │  │
│  │  ─────────────────────────────   │  │
│  │  • /api (red)        1.2K rps    │  │
│  │  • /healthz (blue)   100 rps     │  │
│  └──────────────────────────────────┘  │
│                                        │
│  ┌──────────────────────────────────┐  │
│  │ Error rate                       │  │
│  │  [stat panel]                    │  │
│  │           0.4%                   │  │
│  └──────────────────────────────────┘  │
└────────────────────────────────────────┘
```

### Grid → single column

Grafana dashboards are laid out on a 24-column grid (`gridPos.x` + `w`
identify columns, `y` + `h` identify rows). On a phone we **collapse to
a single column** in render order.

Render order is `panels[]` array order, with a tiebreaker on `gridPos.y`
then `gridPos.x` for dashboards that aren't stored in render order. We
do not implement a true responsive grid (it doesn't add value at phone
width).

Panel min-heights are computed from `gridPos.h`:

```swift
let pointsPerRow = 30.0    // Grafana's web convention
let minHeight = CGFloat(panel.gridPos.h) * pointsPerRow
```

Capped at 240pt minimum and 480pt maximum, regardless of `h`. This
prevents a stretched stat panel that's "supposed" to be huge from taking
the whole screen.

### `row` panels become section headers

A `row` panel (Grafana's collapsible-row separator) renders as:

```
─────────  CPU & Memory  ─────────
```

…followed by the panels that belong to that row (Grafana's data model
puts row panels inline in `panels[]` with subsequent panels implicitly
"under" them until the next row).

### Collapsed rows

Grafana lets users collapse rows. The dashboard JSON has `collapsed: true`
on the row panel, with the row's panels nested under `row.panels`. v1
expands collapsed rows on mobile (we don't have screen real estate to
play with) — document this.

## Time range

### Picker UI

```
[now-6h ▾]
       │
       ▼
┌────────────────────────────────┐
│  Quick                         │
│  • Last 5 minutes              │
│  • Last 15 minutes             │
│  • Last 1 hour                 │
│  • Last 6 hours       ✓        │
│  • Last 24 hours               │
│  • Last 7 days                 │
│  ───────                       │
│  Custom                        │
│  From  [date+time]             │
│  To    [date+time]             │
│  [ Apply ]                     │
└────────────────────────────────┘
```

### Internal representation

```swift
enum DashboardTimeRange {
  case relative(from: String, to: String)   // ("now-6h", "now")
  case absolute(from: Date, to: Date)
}

struct ResolvedTimeRange {                  // post-resolution
  let from: Date
  let to: Date
  var duration: TimeInterval { to.timeIntervalSince(from) }
  var fromMillis: String { String(Int64(from.timeIntervalSince1970 * 1000)) }
  var toMillis: String { String(Int64(to.timeIntervalSince1970 * 1000)) }
}
```

`DashboardDetailModel` holds a `DashboardTimeRange`. On each query, we
resolve it against the current clock and produce a `ResolvedTimeRange`.
For relative ranges this means "last 6 hours" continues to track the
current clock as time advances (correct UX); for absolute ranges the
resolution is a no-op.

### Parser grammar for `now-…` strings

```
expr   := "now" ("/" unit)? | "now" ("-" | "+") integer unit ("/" unit)?
unit   := "s" | "m" | "h" | "d" | "w" | "M" | "y"
integer := [0-9]+
```

Examples:

| String | Meaning |
| --- | --- |
| `now` | the current moment |
| `now/d` | start of today (UTC) |
| `now-1h` | one hour ago |
| `now-1d/d` | start of yesterday |
| `now-7d/d` | start of the day 7 days ago |
| `now+1h` | one hour from now (rare) |

Edge cases handled:

- The trailing `/<unit>` rounds *down* to the start of that unit. `now/h`
  → start of current hour.
- Combining: `now-1d/d` is "subtract 1 day, then round down to day start".
- Timezone: Grafana's expressions are evaluated in the dashboard's
  timezone (`DashboardJSON.timezone`). v1: if `timezone == "browser"`
  or empty, use device timezone; if it's an IANA name, use that. We use
  `Calendar` with the appropriate `TimeZone` for rounding.

### Picker → DashboardTimeRange

The quick presets map directly:

```swift
let presets: [(label: String, range: DashboardTimeRange)] = [
  ("Last 5 minutes",  .relative(from: "now-5m",  to: "now")),
  ("Last 15 minutes", .relative(from: "now-15m", to: "now")),
  ("Last 1 hour",     .relative(from: "now-1h",  to: "now")),
  ("Last 6 hours",    .relative(from: "now-6h",  to: "now")),
  ("Last 24 hours",   .relative(from: "now-24h", to: "now")),
  ("Last 7 days",     .relative(from: "now-7d",  to: "now")),
]
```

Custom range opens a date+time picker for both ends. We don't expose the
`now-…/d` (rounding) syntax in the picker — that's expert territory and
the result of rounding is non-obvious. Dashboards that ship with such a
default range will still resolve correctly (we don't rewrite the
dashboard's default).

### Time range persistence

When a user changes the time range on a dashboard, the change persists
**only for that dashboard's open session** — we don't write back to the
dashboard JSON (read-only mode) and we don't remember it across opens.
Next time the user opens that dashboard, it's at the dashboard's default
range again. This matches Grafana's own behavior when "URL time range"
isn't part of the deep link.

## Variables

Variables live in `dashboard.templating.list[]`.

```json
{
  "templating": {
    "list": [
      {
        "name": "env",
        "type": "query",
        "label": "Environment",
        "datasource": {"uid":"prom","type":"prometheus"},
        "query": "label_values(up, env)",
        "current": {"text":"production","value":"production","selected":true},
        "options": [],
        "multi": false,
        "includeAll": false
      },
      {
        "name": "instance",
        "type": "query",
        "datasource": {"uid":"prom","type":"prometheus"},
        "query": "label_values(up{env=\"$env\"}, instance)",
        "multi": true,
        "includeAll": true,
        "allValue": ".*"
      }
    ]
  }
}
```

### Variable types we support in v1

| Type | Behavior |
| --- | --- |
| `query` | Resolves a query against a datasource and offers the results as options |
| `custom` | A fixed comma-separated list in the variable definition |
| `constant` | A non-interactive constant (not surfaced in the variable bar) |

### Types we defer

| Type | Why |
| --- | --- |
| `interval` | Less common; needs interval-math substitution |
| `datasource` | UX of switching a panel's datasource is large |
| `textbox` | Free-form input on a phone is awkward |
| `adhoc` | Generates label-filter clauses dynamically; complex |

Unsupported variable types render as disabled rows in the variable bar
with "(unsupported)" — the panels using them still try to substitute,
which may produce broken queries; the user can see the variable is the
cause.

### Variable resolution

Two-pass:

1. **Load.** For each variable in order:
   - `constant`: take the literal `current.value`.
   - `custom`: parse `query` as comma-separated values; use `current.value`
     if set or the first option.
   - `query`: substitute any earlier variables into the query string, then
     issue the resolved query against the variable's datasource. Parse
     the response into a list of options. Use `current.value` if it's
     still in the option list, else the first option.

2. **Apply.** For each panel target, substitute every variable value into
   the target's `expr` / `query` string before sending to `/api/ds/query`.

Variables resolve in declaration order, so a later variable's query can
reference an earlier one. Cycle detection: if we detect a cycle during
load we abort and show "Variable cycle detected" in the variable bar.

### Variable query types

`query`-type variables use datasource-specific query syntax:

| Datasource | Query syntax | Example |
| --- | --- | --- |
| Prometheus | `label_values(<series>, <label>)` | `label_values(up{env="$env"}, instance)` |
| Prometheus | `label_values(<label>)` | `label_values(env)` |
| Loki | `label_values(<label>)` | `label_values(job)` |

For Prometheus we hit `/api/datasources/proxy/<id>/api/v1/series` or
`/api/v1/label/<label>/values`. To avoid having to parse and route every
variant in v1, we use the simpler approach: send the variable query
through `/api/ds/query` with the appropriate datasource — Grafana's
own resolver handles the syntax for us, and we read the resulting frame.

For Loki, same trick.

This means our variable resolution is "send the query string to Grafana,
let Grafana figure it out, parse the result". Less work, fewer bugs from
mismatched syntax.

### Substitution grammar

Substitute every occurrence of:

- `$varname`
- `${varname}`
- `${varname:format}`

…in the target string. `format` ∈:

| Format | Behavior for `[a, b, c]` |
| --- | --- |
| (none) | `a,b,c` (Grafana's "glob" default) |
| `csv` | `a,b,c` |
| `pipe` | `a\|b\|c` |
| `regex` | `(a\|b\|c)` |
| `lucene` | `(a OR b OR c)` |
| `singlequote` | `'a','b','c'` |
| `doublequote` | `"a","b","c"` |
| `raw` | `{a,b,c}` |

v1 implements the first 5. Others fall back to `csv` with a console
warning logged.

Single-value variables substitute literally:

```
$env  → "production"
${env} → "production"
${env:singlequote} → "'production'"
```

If `includeAll` is set and the user picks "All":

```
substitution = variable.allValue ?? "(.+)"
```

### Variable bar UI

```
Variable: env   [production ▾]      ← single-value
Variable: instance [3 selected ▾]    ← multi-value, picker pops a checklist
```

Tapping opens a sheet with the variable's options. Multi-value variables
get a checklist with "Select all" / "Clear" actions; single-value
variables get a radio list. "Apply" closes the sheet and re-queries
panels.

### Variable change cost

Every variable change triggers a re-query of every panel that uses that
variable. We don't try to be clever about which panels are affected;
re-query all panels (cheap, one round-trip each, runs concurrently).

## Annotations

Endpoint: `GET /api/annotations?dashboardUID=<uid>&from=<ms>&to=<ms>`.

```json
[
  {
    "id": 42,
    "alertId": 7,
    "dashboardUID": "abc",
    "panelId": 3,
    "time": 1700000000000,
    "timeEnd": 1700000060000,
    "text": "Deploy: api v1.2.3",
    "tags": ["deploy"],
    "type": "alert"
  }
]
```

Annotations are rendered as `RuleMark` overlays on `timeseries` panels at
the matching timestamps. If `timeEnd != time`, render as a translucent
`RectangleMark` spanning the interval.

Annotation tap → bottom-sheet with text + tags + linked alert (if
`alertId` set, link to the alert's detail screen).

Detail in [`08-search-starred-annotations.md`](08-search-starred-annotations.md).

---

Onward: [`07-alerts.md`](07-alerts.md).
