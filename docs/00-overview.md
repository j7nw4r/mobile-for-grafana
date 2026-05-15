# 00 — Overview

## What we're building

A native iOS app, written in Swift / SwiftUI, that lets a Grafana operator
browse their organization's dashboards, alerts, and search results from a
phone. The app talks directly to a **self-hosted Grafana OSS or Enterprise**
instance over HTTPS, and renders dashboard panels natively using Swift Charts —
not by embedding the Grafana web UI in a `WKWebView`, and not by relying on
the server-side image renderer plugin.

The app is intentionally *read-mostly*. The only write verbs in v1 are:
silence creation, starring/unstarring a dashboard, and the implicit writes of
auth flows (login / logout). Everything else is observation.

## Why this exists

Grafana has an excellent web UI. It is not a great phone experience. The
panels are dense, the navigation is keyboard-and-mouse oriented, and the
mobile-web rendering of a multi-row dashboard is hard to read on a small
screen. Operators carrying a phone to an on-call rotation want a leaner view:
"is the thing on fire, and if so, where?" That is the problem we solve.

## Target user

A Grafana operator at a small-to-medium organization. They:

- run their own Grafana instance (OSS or Enterprise);
- already have a service-account token or basic-auth credentials they use
  with `grafana-cli` or `curl`;
- are on iOS;
- are most commonly trying to *look at* something — a dashboard, an alert
  state, a recent annotation — not to configure or edit.

Out of scope as a target user (for v1): Grafana Cloud customers, Android
users, dashboard authors, observability platform admins managing many
tenants.

## In scope (v1)

| Feature | Notes |
| --- | --- |
| Login (3 methods) | Service-account token, basic auth, OIDC via cookie harvest |
| Browse folders + dashboards | Standard tree, plus a "starred" filter |
| Open a dashboard | Title, time range, variable bar, scrollable panel list |
| Render panels natively | timeseries, stat, gauge, bargauge, table, logs |
| Time range picker | Relative presets + absolute custom range |
| Dashboard variables | `query`, `custom`, `constant` types only |
| Annotations on timeseries | Vertical rule marks at the right timestamps |
| Global search | Across dashboards by name + tag |
| Starred dashboards | View, star, unstar |
| Alerts list | Current firing / pending state from rule engine |
| Alert detail | Rule definition + recent state + matchers |
| Silence creation | Standard Alertmanager v2 silence shape |
| Multi-server | Switch between two or more Grafana instances |

## Non-goals (v1)

These are explicit decisions to *not* build, not omissions:

- **Grafana Cloud.** Different auth, different URL conventions, different
  rate-limiting. Punt to a follow-up release.
- **Android.** Single-platform focus for v1.
- **Explore / ad-hoc queries.** A native PromQL/LogQL editor on a phone is a
  large feature surface — not the highest-leverage use of a mobile session.
- **Dashboard editing.** Read-mostly is the whole pitch.
- **Provisioning of alert rules / contact points / notification policies.**
  The Grafana provisioning API supports CRUD; we won't expose it.
- **Live streaming via WebSocket.** Grafana supports it; we'll start with
  pull-to-refresh + a manual refresh verb to keep complexity bounded.
- **Heatmap, geomap, node-graph, traces, alert-list, news, candlestick
  panels.** Visual surface area is large; v1 covers the panel types that
  account for most operator-facing dashboards.
- **Datasource-managed alerts** (e.g. Prometheus AlertManager pointed at by
  Grafana). v1 surfaces Grafana-managed alerts only.
- **Interval / datasource / textbox / adhoc variable types.** v1 supports
  `query`, `custom`, `constant`.
- **Analytics / telemetry collection.** None in v1.
- **Push notifications.** Out of scope — the app is pull-based.

## Reference-app analogy

`alexmt/mobile-for-argocd` is the *product shape* inspiration. The translation
table:

| ArgoCD-app concept | Grafana-app equivalent |
| --- | --- |
| Server URL + token | Same — paste a Grafana URL + token |
| Apps list (tab 1) | Dashboards list / starred / recent (tab 1) |
| Filters: sync state, health, project | Filters: folder, starred, tag |
| Sync / hard-refresh / rollback | (None — we're read-mostly) |
| Resource tree | (None — Grafana has no equivalent concept) |
| Diff | (None) |
| Log streaming | Panel-level: Loki logs panel rendering |
| OIDC PKCE via Dex | Cookie harvest via `/login/<provider>` (no PKCE path) |
| Username/password fallback | Same — `POST /login` |
| User tab (settings) | Same — server info, current user, switch server |

What carries over: the single-server-at-a-time mental model, the
tab-based UI, Keychain-resident credentials keyed by server, the OIDC
fallback for SSO users, the fastlane / TestFlight release path.

What doesn't carry over: every write verb except silence/star, the
React/Expo codebase itself (we are not porting code), and the assumption
that the server exposes a public OAuth client (Dex does, Grafana doesn't).

## Success criteria (v1)

We will call v1 done when, against a stock Grafana 11.x:

1. A user can paste a server URL + service-account token and reach the
   dashboard list within 5 seconds (token-validated, folders loaded).
2. A user can open a dashboard with timeseries panels backed by Prometheus
   and see the panels render with correct data, correct time range, and
   correct legends.
3. A user can change the time range and see panels re-query.
4. A user can resolve a dashboard variable and see the substitution take
   effect in the queries.
5. A user can browse the alerts tab, see what's firing, open an alert, and
   silence it for a chosen duration.
6. A user can star a dashboard from the detail screen and find it in the
   "Starred" filter on the home screen.
7. The app passes App Review and lands in TestFlight for a small beta group.

## Glossary

These are the terms used throughout the docs. We match Grafana's vocabulary
in code identifiers to avoid translation cost.

- **Server** — a Grafana instance, identified by base URL (e.g.
  `https://grafana.example.com`).
- **Folder** — a Grafana folder. Identified by `uid` (string). May contain
  dashboards.
- **Dashboard** — a Grafana dashboard. Identified by `uid`. Contains panels,
  variables, and time-range defaults.
- **Panel** — one visualization on a dashboard. Has a `type` (`timeseries`,
  `stat`, …), one or more `targets`, and a position in the dashboard grid.
- **Target** — one query inside a panel. Identified by `refId` (single letter
  by convention: `A`, `B`, …). Points at a datasource and carries
  datasource-specific fields (`expr` for Prometheus, etc.).
- **Datasource** — a configured data source on the Grafana server.
  Identified by `uid` and `type` (`prometheus`, `loki`, `testdata`, …).
- **Frame** — one Arrow-style columnar result table. Output unit of
  `/api/ds/query`. A panel response is `{results: {refId: {frames: […]}}}`.
- **refId** — the letter-keyed handle for a target's results inside a panel
  query response.
- **Variable** — a templated value the user can change to re-parameterize
  panel queries. Lives in `templating.list[]` on the dashboard JSON.
- **Time range** — `(from, to)` pair, either absolute (Unix ms) or relative
  (`now-6h`, `now-7d/d`).
- **Annotation** — a point or range event overlaid on time series panels,
  produced by alert state transitions or user creation.
- **Service-account token** — Grafana's recommended long-lived API
  credential. Header form: `Authorization: Bearer <token>`.
- **`grafana_session`** — the HttpOnly session cookie set by basic-auth
  login and OIDC login. Default lifetime 30 days.
- **Silence** — an Alertmanager v2 record matching on labels for a time
  window, suppressing notifications. Closest thing to "acknowledge".

Onward to [`01-architecture.md`](01-architecture.md) for the structural
decisions, or [`11-roadmap.md`](11-roadmap.md) for the implementation
sequence.
