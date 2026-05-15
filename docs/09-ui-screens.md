# 09 — UI screens

Screen-by-screen UI spec. ASCII wireframes for each screen, plus an
explicit enumeration of states: loading / loaded / empty / error /
unauthorized.

Each screen lives in `Features/<feature>/` and is a self-contained SwiftUI
view tree. The `App/` module wires the root navigation; everything below
is per-feature.

## Navigation root

```swift
TabView(selection: $selectedTab) {
  HomeView()      .tabItem { Label("Dashboards", systemImage: "rectangle.grid.2x2") }
  AlertsView()    .tabItem { Label("Alerts",     systemImage: "bell.badge") }
  SearchView()    .tabItem { Label("Search",     systemImage: "magnifyingglass") }
  SettingsView()  .tabItem { Label("Settings",   systemImage: "gear") }
}
.environment(serverContext)
```

If `serverContext.credential == nil`, the entire `TabView` is replaced by
`LoginView()`. Sign-in completion swaps in the `TabView`.

Visual conventions across all screens:

- Dark mode default, light mode supported.
- Navigation: `NavigationStack` per tab (each tab gets its own stack).
- Empty / error / loading states use `ContentUnavailableView` where
  applicable (loading uses a `ProgressView` overlay instead).

## Login

The first screen a new user sees. Three auth methods picked from a
segmented control or menu.

```
┌────────────────────────────────────────┐
│                                        │
│           [ Grafana logo ]             │
│           Mobile for Grafana           │
│                                        │
│  Server URL                            │
│  [ https://grafana.example.com      ]  │
│                                        │
│  Auth method                           │
│  [ Token  |  Password  |  SSO ▾ ]      │  ← segmented
│                                        │
│  ─── (varies by method) ───            │
│                                        │
│  Service-account token                 │  [Token]
│  [ glsa_••••••••••••••              ]  │
│  How to create one ▾                   │
│                                        │
│  Username  [ admin                  ]  │  [Password]
│  Password  [ ••••••••••             ]  │
│                                        │
│  [ Continue with provider ▾        ]   │  [SSO]
│                                        │
│              [   Sign in   ]           │
│                                        │
└────────────────────────────────────────┘
```

### States

- **Idle.** Default. Continue button disabled until URL + credential
  fields validate.
- **Validating.** Continue button shows a `ProgressView`; fields disabled.
- **Error.** Inline red text below the offending field. Error messages
  defined in `02-auth.md`.

### SSO sub-flow

After picking SSO and entering server URL, tapping "Continue with
provider ▾" hits `/api/frontend/settings` to discover OAuth providers.
If multiple, show a sheet:

```
┌────────────────────────────────────────┐
│  Sign in with                          │
│  ──────────────────────────────────    │
│  • Google                              │
│  • GitHub                              │
│  • Generic OAuth (corp SSO)            │
└────────────────────────────────────────┘
```

If exactly one, skip the sheet. Either way, present a modal
`WKWebView`-hosted sign-in flow per `02-auth.md`'s cookie-harvest
approach.

## Home (Dashboards)

```
┌────────────────────────────────────────┐
│  Dashboards                    [↻]    │
│  ──────────────────────────────────    │
│                                        │
│  ★ Starred                  [view all] │
│  ──────────────────────────────────    │
│  • API request rate                    │
│  • Cluster health                      │
│                                        │
│  📊 Recent                             │
│  ──────────────────────────────────    │
│  • Disk usage (Production)             │
│  • Pod restarts (Staging)              │
│                                        │
│  📁 Folders                            │
│  ──────────────────────────────────    │
│  > Production           (12)           │
│  > Staging              (5)            │
│  > Development          (3)            │
└────────────────────────────────────────┘
```

### States

- **Loading** — `ProgressView` centered, no sections rendered.
- **Loaded** — three sections as above.
- **Empty** — `ContentUnavailableView("No dashboards", systemImage:
  "rectangle.grid.2x2", description: Text("Create dashboards in Grafana to see them here."))`.
- **Unauthorized** — global handler redirects to Login with the
  server URL prefilled.
- **Error** — sectioned: each section can fail independently. Show
  per-section inline errors with a retry button.

### Folder detail

Tap a folder row → push a folder-contents view (essentially a scoped
search):

```
┌────────────────────────────────────────┐
│  ← Production                          │
│  ──────────────────────────────────    │
│  [ search this folder...           ]   │
│                                        │
│  • API request rate                    │
│    tags: api, latency                  │
│  • Cluster health                      │
│  • Disk usage                          │
└────────────────────────────────────────┘
```

States: loading / loaded / empty / error.

## Dashboard detail

```
┌────────────────────────────────────────┐
│  ← API request rate              ★ ⋯  │
│  ──────────────────────────────────    │
│  [now-6h ▾]   [↻]                      │
│                                        │
│  Variable: env   [production ▾]        │
│  Variable: cluster [us-east-1 ▾]       │
│  ──────────────────────────────────    │
│                                        │
│  ┌──────────────────────────────────┐  │
│  │ Request rate by handler          │  │
│  │                                  │  │
│  │  [timeseries chart]              │  │
│  │  ─────────────────────────────   │  │
│  │  • /api (red)        1.2K rps    │  │
│  │  • /healthz (blue)   100 rps     │  │
│  └──────────────────────────────────┘  │
│                                        │
│  ┌──────────────────────────────────┐  │
│  │ Error rate                       │  │
│  │           0.4%                   │  │
│  └──────────────────────────────────┘  │
│                                        │
└────────────────────────────────────────┘
```

The "⋯" overflow opens a menu: Annotations, Open in Grafana, Copy
dashboard URL.

### States

- **Loading dashboard JSON** — full-screen spinner with title placeholder.
- **Loaded dashboard, panels loading** — title + toolbar visible, each
  panel card shows its own loading spinner inside.
- **Loaded** — all panels rendered (each card may independently show
  loading / error / empty for its own data).
- **Empty dashboard** — the dashboard exists but has zero panels.
  Render `ContentUnavailableView("Empty dashboard", systemImage:
  "rectangle.dashed", description: Text("This dashboard has no
  panels."))`. Rare but possible.
- **Error fetching dashboard** — `ContentUnavailableView("Couldn't load
  dashboard", systemImage: "exclamationmark.triangle", description: …,
  actions: { Button("Retry", action: retry) })`.
- **Unauthorized** — global 401 handler intercepts and bumps to Login
  with the server URL prefilled. The Dashboard detail view itself does
  not render a 401 state; the navigation stack is replaced.

Per-panel states are documented in [`05-panels-and-charts.md`](05-panels-and-charts.md).

## Panel detail (full-screen)

Tapping a panel card opens it full-screen:

```
┌────────────────────────────────────────┐
│  ← Request rate by handler             │
│  ──────────────────────────────────    │
│  [now-6h ▾]   [↻]                      │
│                                        │
│  ╔══════════════════════════════════╗  │
│  ║                                  ║  │
│  ║  [full chart, taller]            ║  │
│  ║                                  ║  │
│  ╚══════════════════════════════════╝  │
│                                        │
│  Legend                                │
│  • /api                  1.2K rps   ☑  │
│  • /healthz              100 rps    ☑  │
│  • /metrics              30 rps     ☐  │  ← unchecked = hidden
│                                        │
│  Query                                 │
│  rate(http_requests_total[5m])         │
│                                        │
└────────────────────────────────────────┘
```

The panel detail shows the actual query expression(s) below the legend
— useful for the on-call operator who wants to know "what is this
panel actually plotting?".

States: same as panel cards on the dashboard detail. Loading shows a
larger spinner.

## Alerts

```
┌────────────────────────────────────────┐
│  Alerts                       [↻]     │
│  ──────────────────────────────────    │
│  [ All ▾ ]  [ Critical ▾ ]             │
│                                        │
│  🔴 HighCPU                    2/14    │
│    host-1   severity=warning           │
│    CPU > 90% on host-1                 │
│    firing for 5m                       │
│                                        │
│    host-3   severity=warning           │
│    firing for 12m                      │
│                                        │
│  🟡 DiskSpaceLow              1/8     │
│    disk-2                              │
│    pending for 3m                      │
│                                        │
│  ─────────── [Rules]                   │
└────────────────────────────────────────┘
```

A secondary "Rules" link at the bottom opens the rule-list screen (see
[`07-alerts.md`](07-alerts.md)).

### States

- **Loading** — `ProgressView`.
- **Loaded with alerts** — as above.
- **Empty** — `ContentUnavailableView("All clear", systemImage:
  "checkmark.circle", description: Text("Nothing is firing or pending."))`.
- **Error** — message + retry.
- **Forbidden** — token can read but Grafana returns 403 on alerts
  endpoint (Viewer roles can usually read alerts; rare): show
  "Your account doesn't have permission to view alerts" with a link to
  Settings.

## Alert detail

See [`07-alerts.md`](07-alerts.md) for the full wireframe. The detail
screen lives at `Features/Alerts/AlertDetailView.swift`.

States: loading / loaded / error / silence-permission-denied (post-
attempt).

## Search

```
┌────────────────────────────────────────┐
│  Search                                │
│  ──────────────────────────────────    │
│  [🔍 cpu                            ]  │
│                                        │
│  [ #api ]  [ #database ]               │
│                                        │
│  Recent                                │
│  • cpu  (just now)                     │
│  • disk                                │
│                                        │
│  Dashboards                            │
│  • CPU & Memory  (Production)          │
│  • CPU usage by pod  (Kubernetes)      │
│  • Cluster CPU summary  (Production)   │
│                                        │
│  [ Load more ]                         │
└────────────────────────────────────────┘
```

### States

- **Empty (no query)** — show "Recent" section (if any), plus a
  placeholder "Search dashboards by name or tag".
- **Loading** — inline `ProgressView` next to the search field.
- **Results** — as above.
- **Empty results** — `ContentUnavailableView("No matches",
  systemImage: "magnifyingglass", description: Text("Try a different
  word or remove tag filters."))`.
- **Error** — inline error message with retry.

## Settings

```
┌────────────────────────────────────────┐
│  Settings                              │
│  ──────────────────────────────────    │
│                                        │
│  Current server                        │
│  ─────────────────────────────         │
│  grafana.example.com                   │
│  signed in as alice (alice@example.com)│
│  via service-account token             │
│  [ Sign out ]                          │
│                                        │
│  Servers                               │
│  ─────────────────────────────         │
│  • grafana.example.com (current)       │
│  • grafana-staging.example.com         │
│  [ + Add server ]                      │
│                                        │
│  Active silences                       │
│  ─────────────────────────────         │
│  [ View 2 active silences › ]          │
│                                        │
│  About                                 │
│  ─────────────────────────────         │
│  Version 1.0.0 (build 42)              │
│  [ Copy diagnostics ]                  │
│  [ Privacy policy ]                    │
│  [ Source code ]                       │
│                                        │
└────────────────────────────────────────┘
```

### States

- **Loaded** — the layout above. Settings is fundamentally a list of
  static and locally-derived rows, so most state is loaded-by-default.
- **Loading (current-user refresh)** — when the screen appears we
  re-fetch `GET /api/user` in the background to surface name/email
  changes. While in flight, show the cached values; on completion,
  update silently.
- **Error (current-user refresh)** — if the refresh fails with a
  non-401 error, leave the cached values and show a small "couldn't
  refresh user info" badge next to the user row. 401 follows the
  global unauthorized path.
- **Unauthorized** — global handler bumps to Login (same as everywhere
  else). The Settings screen is no longer reachable while signed out.
- **Empty** — N/A. Even with zero non-current servers the Servers
  section still shows the current server row + "Add server" button.

### Sign out

Confirmation alert: "Sign out of grafana.example.com? Your credentials
will be removed from this device." Cancel | Sign out.

### Switch server

Tapping a non-current server row in the Servers list switches to it:
load the Keychain credential for that host, validate with `GET
/api/user`, set as active, tear down per-feature state, refresh.

If the credential validation fails (cookie expired, token revoked),
prompt to re-authenticate with the URL prefilled.

### Add server

Tapping `[ + Add server ]` opens the Login screen as a sheet. On
success the new server is added and switched to.

### Copy diagnostics

Exports the last hour of `OSLog` entries to the share sheet — see
[`01-architecture.md`](01-architecture.md). The text excludes Keychain
contents, request/response bodies, and tokens — only metadata
(endpoints, status codes, error names).

## Loading patterns

| Wait | Pattern |
| --- | --- |
| < 200ms | No indicator (don't flash). |
| 200ms – 2s | `ProgressView` at the screen or section level. |
| 2s – 5s | `ProgressView` + the original content greyed out (for refreshes). |
| > 5s | Same as above; no special handling unless we time out. |

Network timeout: 30s on the URLSession config. If hit, surface
"Request timed out" with a retry button.

## Error pattern cheat sheet

| Error | UI |
| --- | --- |
| `unauthorized` | Bump to Login, prefill URL, show "Your session has expired" |
| `forbidden` | Inline "Your account doesn't have permission to do this" + dim the action |
| `notFound` | `ContentUnavailableView` for the specific resource |
| `rateLimited` | Toast: "Slow down — Grafana is rate-limiting" |
| `serverError` | Inline retry + "Grafana returned an error: {message}" |
| `decode` | "Unexpected response from Grafana. Tap to copy diagnostics." |
| `unreachable` | "Couldn't reach grafana.example.com. Check your VPN?" |

## Accessibility

- Every interactive element gets a `.accessibilityLabel`.
- Charts get `.accessibilityChartDescriptor` (Swift Charts has built-in
  support — we plug in series names, value ranges).
- Color is never the *only* signal. Threshold state additionally shows an
  icon (`exclamationmark.triangle.fill`, etc.).
- Dynamic Type is honored throughout. We don't fight the user's text size
  setting.

## Animations

Default SwiftUI animations only. No custom transitions in v1. The one
exception is the optimistic star toggle, which uses a brief
`.scaleEffect` pulse to confirm the tap.

---

Onward: [`10-build-and-release.md`](10-build-and-release.md).
