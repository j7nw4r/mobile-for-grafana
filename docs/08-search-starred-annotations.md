# 08 — Search, starred, annotations

Three smaller features that share less plumbing than the previous docs.

## Search

### Endpoint

`GET /api/search` with query parameters:

| Param | Value | Notes |
| --- | --- | --- |
| `query` | string | Free-text against title |
| `type` | `dash-db` | We only want dashboards in the global search |
| `tag` | string (repeatable) | AND across multiple `tag` params |
| `starred` | `true` | Filter to starred only |
| `folderUIDs` | comma-sep | We do *not* use this on global search |
| `limit` | int (max 5000) | We page at 100 |
| `page` | int | 1-based |

We default to `limit=100&page=1`. If the response has 100 hits, we expose
an inline "Load more" button that fetches `page=2` and appends.

### UI

```
┌────────────────────────────────────────┐
│  Search                                │
│  ──────────────────────────────────    │
│  [🔍 cpu                            ]  │
│                                        │
│  [ #api ] [ #database ]   ← active tags│
│                                        │
│  Dashboards                            │
│  • CPU & Memory  (Production)          │
│  • CPU usage by pod  (Kubernetes)      │
│  • Cluster CPU summary  (Production)   │
│                                        │
│  [ Load more ]                         │
└────────────────────────────────────────┘
```

### Tag filtering

Tag chips appear under the search field when the user has previously
tapped a tag from a search result. Each chip is removable. The `tag`
parameter is included on the next search.

Tags come from `SearchHit.tags` in results. We do not pre-fetch the
distinct tag set across all dashboards — the user only sees a tag chip
after they've encountered it.

### Debounce

The search field debounces input at 300ms. On every change after the
debounce, the in-flight task is cancelled and a new task issues the
search. Empty query + zero tag chips clears the result list.

### Recent searches

We persist the last 10 search queries in `UserDefaults`. When the user
focuses the search field with empty input, a "Recent" section appears
above the results showing past queries. Tap to re-run; long-press to
forget.

### Empty state

```
[no query, no tags]
  → "Search dashboards by name or tag" placeholder

[query entered, zero results]
  → ContentUnavailableView "No results" with a "Clear filters" button

[query entered, results came back, then user clears query]
  → reverts to placeholder
```

## Starred dashboards

### Endpoints

| Method | Path | Use |
| --- | --- | --- |
| `GET /api/search?starred=true` | List starred dashboards | Home tab "Starred" section |
| `POST /api/user/stars/dashboard/uid/{uid}` | Star a dashboard | Dashboard detail star button |
| `DELETE /api/user/stars/dashboard/uid/{uid}` | Unstar a dashboard | Same button, when already starred |

The `meta.isStarred` field on `GET /api/dashboards/uid/{uid}` tells us the
current star state for the detail-screen button.

### Star button

On the dashboard detail toolbar:

```
[← API request rate ]                ★       ← unfilled when not starred
[← API request rate ]                ★       ← filled (gold) when starred
```

Behavior:

- Tap = toggle.
- Optimistic update: the icon flips immediately, the request runs in the
  background, on failure we revert + show a toast.
- On success we also update the "Starred" section on the home tab
  (`DashboardListModel` listens for star toggles).

### Multi-account quirk

Starring is per-user. A service-account token's starred set is *that
service account's* starred set — typically empty unless someone has
been starring through the UI as that service account. Documented in the
auth doc's help-text: "If you use a service account token, starring may
not be useful unless you also use the service account in Grafana's web
UI."

We don't degrade the UI based on credential type; the star button always
works as far as the API is concerned.

## Annotations

Two surfaces:

1. **Inline on timeseries panels** — overlay `RuleMark`s at the right
   timestamps.
2. **Annotation list view** (optional) — a per-dashboard sheet showing all
   annotations in the current time range, tappable to navigate to the
   panel + zoom-to-annotation.

### Endpoint

```
GET /api/annotations
    ?dashboardUID={uid}
    &from={ms}
    &to={ms}
    &panelId={id}          (optional, filters to one panel)
    &type=annotation       (annotation or alert; omit for all)
    &limit=100             (default 100; we use 500 for dashboards)
```

Response: `[Annotation]` (see `03-api-and-models.md`).

We fetch annotations once per dashboard open + once per refresh, scoped to
the current time range. Per-panel filtering would require N round-trips;
we fetch dashboard-wide and filter client-side by `panelId`.

### Per-panel rendering

For each timeseries panel:

- Filter the dashboard annotations to those with `panelId == panel.id`
  OR `panelId == nil/0` (dashboard-wide annotations apply to all panels).
- For point annotations (`timeEnd == time` or `timeEnd == nil`), draw a
  vertical `RuleMark` at `time`, colored per type.
- For range annotations (`timeEnd > time`), draw a translucent
  `RectangleMark` spanning `[time, timeEnd]`.

### Colors

| Annotation type | Color token |
| --- | --- |
| `alert` | `threshold.red` (consistent with alert severity) |
| `annotation` (user-created) | `accent.blue` |

The Grafana `AnnotationDef.iconColor` field is parsed but not honored in
v1 — we use the two tokens above for consistency. Document.

### Tap behavior

Tapping near an annotation (within ~8pt horizontally) opens a bottom
sheet:

```
┌────────────────────────────────────────┐
│  Deploy: api v1.2.3                    │
│  ──────────────────────────────────    │
│  Time: 14:23:01 (just now)             │
│  Duration: 1m                          │
│  Tags: deploy, api                     │
│                                        │
│  [ View related alert ]   ← if alertId │
│  [ Open in Grafana ]                   │
│                                        │
└────────────────────────────────────────┘
```

"View related alert" navigates to the alerts tab's detail screen for that
alertId (resolved via `/api/prometheus/grafana/api/v1/rules` to find the
matching rule, then the matching instance).

"Open in Grafana" deep-links to
`<server>/d/{uid}?viewPanel={panelId}&from={time}&to={time+1m}` in Safari
(`SFSafariViewController`). The user can read the annotation comment and
related context in the full Grafana UI.

### Annotation list view (per dashboard)

Accessed from the dashboard toolbar overflow menu ("⋯ Annotations"). A
sheet listing all annotations in the current dashboard time range,
chronologically descending, with the same tap behavior as inline
annotations.

### Creation / editing

Out of scope v1. The annotation surface is read-only.

## Recent dashboards

`UserDefaults` stores a capped-at-20 list of `(serverHost, uid, title,
folderTitle, openedAt)` tuples. Each dashboard open prepends; we dedupe
by `(host, uid)` and trim to 20.

The home tab's "Recent" section reads this for the current `activeServer`.

If the user switches servers, the recent list is filtered to that
server — we don't show staging dashboards under production.

## Cross-references

- The home tab pulls from three sources: `starred` (this doc), `folders`
  (`06-dashboards-and-variables.md`), and `recent` (this doc).
- Annotations link to alert detail (`07-alerts.md`).
- Search uses the same `SearchHit` model the folder browser uses
  (`03-api-and-models.md`).

## Tests

`GrafanaViewerTests/Search/` covers:

- Debounce: rapid character input results in one network call per debounce
  window.
- Pagination: a result page of exactly `limit` items shows "Load more"; a
  page of < `limit` doesn't.
- Tag chip add/remove updates the next query's params.

`GrafanaViewerTests/Starred/` covers:

- Optimistic toggle reverts on failure.
- Home tab "Starred" section refreshes when a star is toggled.

`GrafanaViewerTests/Annotations/` covers:

- Per-panel filtering: panel-scoped vs dashboard-wide annotations.
- Point vs range annotation discrimination (`timeEnd == time` is a point).

---

Onward: [`09-ui-screens.md`](09-ui-screens.md).
