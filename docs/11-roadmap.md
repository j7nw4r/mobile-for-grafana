# 11 — Roadmap

The 14-doc design set isn't a release plan. This doc is. It sequences the
work into eight phases, each of which lands a demoable improvement, in an
order chosen so that each phase builds on the previous one without a
half-built ledge.

## Sequencing principles

1. **Vertical slices, not horizontal layers.** Every phase ends with a
   working app you can hand to someone. We do not build the entire
   networking layer, then the entire models layer, then the entire UI
   layer.
2. **Hardest unknowns first, low-risk things last.** Phase 2 (panel
   rendering against real data) and Phase 5 (auth completeness) are the
   biggest risks; they're sequenced early.
3. **The minimum useful credential is a service-account token.** Phases
   0–4 only require token auth. Basic + OIDC come later when the rest of
   the app is proven.
4. **Defer write actions.** Silences (Phase 6) and starring (Phase 7) are
   the only writes. They're late because read-only is the larger surface
   and the part we most want to validate against real Grafanas first.

## Phase 0 — Foundations

**Goal:** an empty-but-real app that logs in and shows the signed-in
user.

**Deliverable:**

- Xcode project (`GrafanaViewer.xcodeproj`) with the directory layout
  from [`01-architecture.md`](01-architecture.md).
- `Auth/Keychain.swift` — wrapper around Security framework.
- `Auth/Credential.swift` — the enum from [`02-auth.md`](02-auth.md).
- `Networking/GrafanaClient.swift` — `URLSession`-backed client with one
  method: `getCurrentUser() async throws -> User`.
- `Models/User.swift`, `Models/GrafanaError.swift`.
- `Features/Login/LoginView.swift` — token-auth only path (URL + token
  fields, Continue button).
- `App/RootView.swift` — picks between `LoginView` and a placeholder
  `SignedInView` showing the user's name.

**Doc references:** `01-architecture.md`, `02-auth.md` (flow 1 only),
`03-api-and-models.md` (User, GrafanaError, FrontendSettings deferred).

**Done when:** I can paste a real Grafana URL + token, the app validates
it, and shows "Signed in as alice (alice@example.com)" on a placeholder
screen.

## Phase 1 — Browse

**Goal:** the user can navigate folders and dashboards and see them
listed.

**Deliverable:**

- `Models/Folder.swift`, `Models/SearchHit.swift`, `Models/DashboardEnvelope.swift`.
- `Networking/GrafanaClient` gains: `listFolders()`, `searchDashboards(query:type:folderUIDs:starred:)`, `getDashboard(uid:)`.
- `Features/DashboardList/HomeView.swift` with the Starred + Folders +
  Recent layout from [`09-ui-screens.md`](09-ui-screens.md).
- `Features/DashboardList/FolderDetailView.swift`.
- `Features/DashboardList/DashboardDetailView.swift` — but **only the
  shell**: title, panel-count, "Panel rendering coming in Phase 2"
  placeholders per panel.
- Recent-dashboards persistence in `UserDefaults`.
- `App/RootView` replaces the placeholder `SignedInView` with the
  `TabView` (Dashboards + Settings only for now; Alerts + Search disabled).

**Doc references:** `03-api-and-models.md`, `06-dashboards-and-variables.md`
(folder browsing + grid collapse only — no variables, no time range yet),
`09-ui-screens.md` (Home, Folder detail, Dashboard detail shell).

**Done when:** I can drill from the home tab into a folder, into a
dashboard, and see a list of panel placeholders with the correct titles.

## Phase 2 — Render (the big one)

**Goal:** timeseries + stat panels render real data.

**Deliverable:**

- `Models/Panel.swift`, `Models/Target.swift`, `Models/FieldConfig.swift`,
  `Models/Frame.swift`, `Models/JSONValue.swift`.
- `DataSources/PrometheusQueryBuilder.swift` (initial impl) +
  `DataSources/TestDataQueryBuilder.swift` (for dev).
- `DataSources/FrameDecoder.swift` + `TimeSeriesDecoder.swift`.
- `Networking/GrafanaClient.queryDatasource(...)`.
- `Panels/PanelCardView.swift` — chrome (title, refresh, loading/error
  states).
- `Panels/TimeSeriesPanelView.swift`.
- `Panels/StatPanelView.swift` (reductions + sparkline + threshold colors).
- `Theme/Color.swift` + asset catalog colors.
- `Models/UnitFormatter.swift` (the 12 most common units).
- `Features/DashboardDetail/TimeRangePicker.swift` — relative presets only,
  no custom range yet.
- `integration/` — `docker-compose.yml` (Grafana OSS + Prometheus),
  provisioning files, kitchen-sink dashboard, and a token-bootstrap
  script. `GrafanaViewerIntegrationTests` target with the first two cases
  (`/api/ds/query` shape + `DashboardEnvelope` decode). Opt-in: skipped
  when `GRAFANA_URL` / `GRAFANA_TOKEN` are unset, so the default
  `xcodebuild test` stays offline. Full design in
  [`12-integration-testing.md`](12-integration-testing.md).

**Doc references:** `04-datasource-queries.md`,
`05-panels-and-charts.md` (timeseries + stat sections + thresholds +
units), `06-dashboards-and-variables.md` (time range — relative only),
`12-integration-testing.md` (integration harness intro + Phase 2 cases).

**Done when:** Against a real Grafana with a Prometheus datasource, I
can open a dashboard with a timeseries panel and a stat panel and see
correct data with the right legend, colors, and value formatting. The
integration suite passes locally against the docker-compose stack.

## Phase 3 — More panels

**Goal:** the remaining v1 panel types.

**Deliverable:**

- `Panels/GaugePanelView.swift` (Canvas-drawn arc).
- `Panels/BarGaugePanelView.swift`.
- `Panels/TablePanelView.swift`.
- `Panels/LogsPanelView.swift`.
- `DataSources/LokiQueryBuilder.swift`.
- `DataSources/TableDecoder.swift` + `LogStreamDecoder.swift`.
- Panel detail (full-screen) view.
- Long-press-to-inspect gesture on timeseries panels.

**Doc references:** rest of `05-panels-and-charts.md`,
`04-datasource-queries.md` (Loki section).

**Done when:** A "kitchen sink" dashboard with all six v1 panel types
renders correctly.

## Phase 4 — Variables and annotations

**Goal:** dashboards with variables and annotation overlays work.

**Deliverable:**

- `Models/Variable.swift`, `Models/AnnotationDef.swift`,
  `Models/Annotation.swift`.
- `Features/DashboardDetail/VariableBar.swift`.
- `Features/DashboardDetail/VariableModel.swift` — load + substitute
  logic.
- `Features/DashboardDetail/CustomTimeRangePicker.swift` (absolute
  range; rounds out the time range picker).
- Annotation overlays on timeseries panels.
- Annotation tap bottom sheet.

**Doc references:** `06-dashboards-and-variables.md` (variables
section + time-range custom range),
`08-search-starred-annotations.md` (annotations section).

**Done when:** A dashboard with three query variables + an annotation
data source renders, variable changes re-query panels, and annotations
appear as rule marks on timeseries charts.

## Phase 5 — Auth completeness

**Goal:** basic auth + OIDC cookie harvest work.

**Deliverable:**

- `Auth/LoginFlow.swift` — orchestrator with three sub-flows.
- `Auth/BasicAuthFlow.swift` — `POST /api/login` + cookie extraction.
- `Auth/OIDCCookieHarvestFlow.swift` — WKWebView-hosted flow.
- `Features/Login/LoginView.swift` gains the segmented auth-method
  control + the per-method form section.
- `Features/Login/SSOProviderPicker.swift` — for the multi-provider case.
- `Models/FrontendSettings.swift`.
- `Networking/GrafanaClient` gains `getFrontendSettings()`,
  `loginWithPassword(_:_:)`.

**Doc references:** `02-auth.md` flows 2 and 3 in full.

**Done when:** Against a Grafana with both basic auth and Google OIDC
configured, I can sign in via each method and use the app for the rest
of the session.

## Phase 6 — Alerts + silences

**Goal:** the Alerts tab works end-to-end.

**Deliverable:**

- `Models/AlertInstance.swift`, `AlertRule.swift`, `AmAlert.swift`,
  `Silence.swift`, `Matcher.swift`.
- `Networking/GrafanaClient` gains `listAlerts()`, `listAlertRules()`,
  `listAmAlerts()`, `listSilences()`, `createSilence(_:)`,
  `expireSilence(id:)`.
- `Features/Alerts/AlertListView.swift` + grouping by alertname +
  state/severity filters.
- `Features/Alerts/AlertDetailView.swift` — labels, annotations, rule,
  silence-creation entry point.
- `Features/Alerts/SilenceSheet.swift` — the silence creation UX.
- `Features/Alerts/RuleListView.swift` — accessed from a "Rules" link
  on the alerts list.
- `Features/Settings/SilenceListView.swift`.
- `App/RootView` re-enables the Alerts tab.

**Doc references:** `07-alerts.md` in full.

**Done when:** Against a Grafana with active firing alerts, I can view
the list, drill into a detail, silence an alert for 1 hour with a
default matcher set, see it appear in the silences list, and expire it
from there.

## Phase 7 — Search + starred

**Goal:** global search and starring complete the v1 feature set.

**Deliverable:**

- `Features/Search/SearchView.swift` — debounced field + paginated
  results + tag chips + recent searches.
- `Features/Search/SearchModel.swift`.
- Star button on the dashboard detail toolbar.
- `Networking/GrafanaClient.starDashboard(uid:)` +
  `unstarDashboard(uid:)`.
- Home tab Starred section refreshes on star toggle (via shared model).
- `App/RootView` re-enables the Search tab.

**Doc references:** `08-search-starred-annotations.md` (search and
starred sections).

**Done when:** I can search "cpu" across the whole Grafana, refine with
a `#kubernetes` tag chip, star a dashboard from its detail page, and see
it appear in the home Starred section.

## Phase 8 — Polish + TestFlight

**Goal:** the app is ready for an internal beta.

**Deliverable:**

- Empty + error + unauthorized states wired up on every screen per
  `09-ui-screens.md`.
- Settings screen: current server, server list, switch server, add
  server, sign out, diagnostics, about.
- Multi-server support fully wired.
- `OSLog` instrumentation across `Networking`, `Auth`, `Panels`.
- `fastlane/` setup; match repo; `BetaTest` scheme + configuration.
- App icon (any non-placeholder version) + asset catalog colors
  finalized.
- `Assets.xcassets/AppIcon.appiconset` with all required sizes.
- Privacy policy + support pages on a static website.
- First TestFlight build, internal-testers group.
- External-beta closed group set up (invite-only) with 5–10 testers
  recruited.

**Doc references:** `09-ui-screens.md` (all states),
`10-build-and-release.md` (TestFlight section in full), `01-architecture.md`
(diagnostics section).

**Done when:** Internal team has the app on their phones and is using it
against their own Grafanas. External closed-beta invitations have gone
out.

## After Phase 8

Not a phase — a non-binding list of things we'll consider for v1.1+
after we see beta feedback:

- Auto-refresh on dashboards (with battery-aware policy).
- More panel types (heatmap, alert-list).
- More variable types (interval, datasource).
- More datasources (CloudWatch, Elasticsearch).
- Stacked / multi-Y-axis timeseries.
- Push notifications for alert state changes (likely via a small
  companion service — outside the app's read-mostly stance).
- Grafana Cloud support.
- Android app (separate Kotlin codebase, not a port).
- Apple Watch complication ("are we on fire? glyph").

## Schedule estimates

This is a side-project rhythm — assume 8–12 hours of focused work per
phase, with non-trivial calendar gaps between. Concrete dates are not
useful because they always slip; relative effort is:

| Phase | Relative effort |
| --- | --- |
| 0 — Foundations | 1× |
| 1 — Browse | 1× |
| 2 — Render | **3×** (the hardest phase by far) |
| 3 — More panels | 2× |
| 4 — Variables + annotations | 2× |
| 5 — Auth completeness | 2× (OIDC harvest is fiddly) |
| 6 — Alerts + silences | 2× |
| 7 — Search + starred | 0.5× |
| 8 — Polish + TestFlight | 2× |

Total: ~15.5× the size of Phase 0. If Phase 0 takes a weekend, the whole
v1 is roughly two-and-a-half person-months of weekend work — which is
realistic.

## How to start Phase 0

Steps the first implementer takes:

1. Read `00-overview.md`, `01-architecture.md`, `02-auth.md`,
   `03-api-and-models.md` end to end.
2. Open Xcode, File → New → Project → iOS App, SwiftUI, Swift, no Core
   Data, no tests checked initially. Place the project at the repo
   root.
3. Add the directory structure from `01-architecture.md`. Delete the
   placeholder `ContentView.swift`.
4. Add `GrafanaViewerTests` target.
5. Implement in the order listed in Phase 0's deliverable list. Don't
   add anything beyond it — the discipline matters.
6. Sanity-check against a real Grafana (use `play.grafana.org` if you
   don't have your own — note it doesn't expose service-account tokens
   to the public, so prefer a local docker-compose Grafana for dev).

When Phase 0 lands, the diff should be small enough to review in one
sitting. If it isn't, scope cut.

---

End of the doc set. Implementation starts at Phase 0.
