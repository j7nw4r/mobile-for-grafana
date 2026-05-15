# 01 — Architecture

## Platform target

- **iOS 17.0+.** Hard requirement, not an aspiration.
- **Swift 5.10+.**
- **SwiftUI** as the primary UI framework. UIKit only where there is a
  concrete framework dependency (the OIDC flow embeds `ASWebAuthenticationSession`).
- **Xcode 15.4+** as the build environment.

The iOS 17 floor buys us four things we'd otherwise have to build around:

| Feature | Why we need it |
| --- | --- |
| `@Observable` / Observation framework | State management without Combine boilerplate |
| Mature `NavigationStack` | Replaces fragile `NavigationView` chains |
| Modern Swift Charts | `AreaMark`, `RuleMark`, axis customization required for panels |
| `ContentUnavailableView` | Standard empty/error state, used on every screen |

Dropping iOS 16 support also drops `ObservableObject` and the `@StateObject` /
`@ObservedObject` distinction, which simplifies the state-management story
substantially (see below).

## Module boundaries

The app lives under one Xcode target (`GrafanaViewer`), but the code is
organized into directories that have explicit dependency rules. Cycles
between them are a build-time error to chase down.

```
GrafanaViewer/
  App/             ── entry point, root TabView, environment wiring
  Auth/            ── credential model, Keychain wrapper, login flows
  Networking/      ── GrafanaClient (URLSession wrapper, request builders)
  Models/          ── Codable types: Dashboard, Panel, Frame, Alert, …
  DataSources/     ── per-datasource query builders + frame decoders
  Panels/          ── Swift Charts renderers per panel type
  Features/        ── one folder per feature (Login, DashboardList, …)
  Theme/           ── colors, typography, spacing constants
  Resources/       ── Assets.xcassets, Info.plist, entitlements
```

### Dependency rule

```
       ┌──── App ────┐
       │             │
       ▼             ▼
   Features <──── Theme
       │
       ▼
     Panels  ←── DataSources ──► Models
       │             │
       └────► Networking ◄───────┘
                    │
                    ▼
                  Auth
```

Stated as rules:

- **`Auth`** depends on nothing else.
- **`Networking`** depends on `Auth` (for credentials) and `Models` (for
  decoding shared types like errors). Does not know about features or
  panels.
- **`Models`** depends on nothing (pure Codable types + helpers).
- **`DataSources`** depends on `Models` and `Networking`. Knows about
  Prometheus and Loki query shapes; does not know about SwiftUI.
- **`Panels`** depends on `Models` and `Theme`. Pure SwiftUI views fed by
  decoded models — does not call the network.
- **`Features`** depends on everything except `Auth` (which it accesses via
  `Networking`'s credential plumbing).
- **`Theme`** depends on nothing.
- **`App`** wires it together via `.environment(...)`.

If you find yourself wanting to import `Features` from `Panels` or
`Networking`, stop — that's a layering violation. Panels should be
stateless renderers fed data; their containing feature owns fetching.

## State management

**Decision: `@Observable` + `.environment(...)` injection.** No Combine,
no The Composable Architecture, no Redux, no MVVM-with-`ObservableObject`.

Rationale:

- The iOS 17 floor makes `@Observable` available everywhere we'll run, so we
  don't need `ObservableObject` as a fallback.
- Combine is fine but adds vocabulary (`Publisher`, `Subject`, `sink`,
  `assign(to:)`, cancellable storage) that buys us nothing for a
  request-and-render app. `async`/`await` is the cleaner equivalent.
- TCA / Redux are appropriate when state-flow correctness is the dominant
  cost. Our state is: "credential is set or not", "this list is loading or
  loaded", "this dashboard is at this time range". That doesn't need a
  reducer/effect framework.

### State holders we will have

These are `@Observable` classes wired via `.environment(\.serverContext)`
or equivalent custom environment keys.

| Holder | Lives | Owns |
| --- | --- | --- |
| `ServerContext` | App-level | Active server URL, credential, `GrafanaClient` instance |
| `DashboardListModel` | DashboardList feature | Folders list, dashboards list, loading + error state |
| `DashboardDetailModel` | DashboardDetail feature | The dashboard, current time range, variable values, per-panel data |
| `AlertListModel` | Alerts feature | Alert instances + their detail state |
| `SearchModel` | Search feature | Query text (debounced), results |

`ServerContext` is the only one that crosses feature boundaries. Everything
else is local to one feature directory.

### What about server switching?

Changing the active server replaces `ServerContext` wholesale. Per-feature
state holders are scoped to the SwiftUI view tree of that feature; replacing
the context tears down the views, which throws away the per-feature models —
that's correct behavior, we *want* the dashboard list to reload when the
server changes.

## Networking

`GrafanaClient` is a small wrapper over `URLSession` that:

- Holds the active server URL + credential.
- Builds requests via `URLRequest` directly.
- Decodes responses into `Models/` types.
- Maps non-2xx responses to a `GrafanaError` enum.
- Knows about credential type to decide between `Authorization: Bearer …`
  and `Cookie: grafana_session=…` request headers.

It does *not*:

- Cache responses (we rely on `URLSession`'s default cache + explicit refresh).
- Retry. If a single request fails, the feature surfaces the error.
- Mutate any state. It returns values.

The protocol-shaped boundary for testing is `URLSessionProtocol` (we'll
define a one-method protocol with `data(for:) async throws -> (Data,
URLResponse)` and make `URLSession` conform). Tests pass a fake that returns
canned responses; production code passes `URLSession.shared`.

## Concurrency

- All I/O is `async`/`await`.
- `@MainActor` annotations on `@Observable` state holders so SwiftUI
  observation lands on the main thread without ceremony.
- `Task` cancellation is honored: a feature that navigates away mid-fetch
  cancels its in-flight `Task`.
- No `DispatchQueue` calls in feature code. (We may need one inside
  `URLSession` extension code for `URLSessionDelegate` callbacks if we end
  up needing custom redirect handling for the OIDC flow — that's the only
  place.)

## Persistence

Two backing stores, chosen for what they're good at:

- **Keychain** — credentials only. One `kSecClassGenericPassword` item per
  server, keyed by host. Implemented in `Auth/`.
- **`UserDefaults`** — everything else: known server URLs, last-used server,
  recent dashboards (capped at 20), favorite time-range presets, expanded-folder state.

We are not using SQLite, Core Data, SwiftData, or a JSON-on-disk cache in
v1. Dashboards are refetched on open. If this becomes a meaningful UX
problem we'll add an offline cache in a later release.

## Logging + diagnostics

- `OSLog` with one subsystem (`com.grafanaviewer.app`) and one category per
  module (`auth`, `network`, `panels`, …).
- No file logging in v1.
- A simple "copy diagnostics" button in Settings that exports the last hour
  of OSLog entries to the share sheet — used by us, not by users.

## Theming

Dark mode primary, light mode supported. Color tokens live in `Theme/`:

```swift
enum Color {
  static let background = Color("background")        // ~black in dark
  static let surface    = Color("surface")
  static let primary    = Color("primary")           // signature accent
  static let textPrimary, textSecondary, textMuted
  static let alertCritical, alertWarning, alertOk
}
```

Asset-catalog backed (`background.colorset`, etc.) so each token has a
dark + light variant. No hardcoded RGB values in feature code.

## Frameworks we use

- `SwiftUI`
- `Charts` (Swift Charts)
- `Foundation`
- `URLSession`
- `AuthenticationServices` (`ASWebAuthenticationSession`)
- `Security` (Keychain APIs)
- `OSLog`

**Zero** third-party Swift packages in v1. If a phase needs one (the most
likely candidate is a Keychain convenience wrapper), the doc for that phase
must justify it explicitly and propose a vendored alternative.

## Sequence: cold launch → dashboard list

```
[user opens app]
       │
       ▼
   App.init ─────────────► load known-servers from UserDefaults
       │
       ▼
   Is there an active server? ────► no ────► show LoginScreen
       │ yes
       ▼
   Load credential from Keychain ─► missing ─► show LoginScreen
       │ found
       ▼
   GrafanaClient.getCurrentUser() ──► 401 ──► clear credential, show Login
       │ 200
       ▼
   Build TabView { Home, Alerts, Search, Settings }
       │
       ▼
   Home tab loads:
     ├─ GET /api/folders        ───► folders state
     └─ GET /api/search?starred=true ───► starred dashboards state
```

## Sequence: panel render

```
DashboardDetailModel.open(uid)
       │
       ▼
   GET /api/dashboards/uid/{uid}
       │
       ▼
   Parse DashboardEnvelope → store dashboard, defaults, variables
       │
       ▼
   For each panel:
     ├─ Build per-target queries via DataSources/
     ├─ Resolve variables → substituted exprs
     └─ POST /api/ds/query  (one request per panel, or batched per refresh)
       │
       ▼
   For each panel result:
     ├─ FrameDecoder → TimeSeries | Table | Logs
     └─ Hand model to the matching Panels/ view
       │
       ▼
   SwiftUI renders panels in scrollable list
```

We deliberately do one query per panel (not one mega-request per dashboard).
Reasons: panel-level error isolation, panel-level retry, and the ability to
re-query one panel without refetching the others. The cost is more HTTP
round-trips; on HTTP/2 this is rarely material.

## Open question to resolve here

> Do we commit to `@Observable` (iOS 17+) and drop iOS 16 support, or use
> `ObservableObject` for one more major iOS cycle?

**Resolution: commit to `@Observable`, iOS 17+.** Two reasons:

1. iOS 17 adoption among Grafana operators (a technical audience on
   recent hardware) is >95% by spring 2026 according to public StatCounter
   data. The dropped audience is small.
2. The simplification in state-management code is large enough to be
   worth it, and `@Observable` is the framework's stated direction.

We will revisit if v1 beta feedback shows a meaningful "I'm on iOS 16"
cohort.

---

Onward: [`02-auth.md`](02-auth.md).
