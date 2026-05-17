# 13 — Testing plan

How we test this app. Three layers, each for a different kind of
confidence; per-phase verification checklist; and the things we
deliberately don't test.

## Layers

| # | Layer | Tooling | Speed | When it runs |
| --- | --- | --- | --- | --- |
| 1 | Unit | XCTest + mocks | < 1 s per case | Every commit, every PR, every CI run |
| 2 | Integration | XCTest against live Grafana | seconds per case | Locally before merging changes to `Networking/` / `DataSources/` / `Models/`; CI gated, opt-in |
| 3 | Manual sim | iOS Simulator + human eyes | minutes | Each phase's "Done when" criterion |

Each layer catches things the layers below can't. Unit tests can't catch
real Grafana behavior; integration tests can't catch UI rendering;
manual checks can't run often enough to catch regressions. They compose.

## Layer 1 — Unit tests

Lives in `GrafanaViewerTests`. Run by default with
`xcodebuild -scheme GrafanaViewer test`.

### Conventions

From [`CLAUDE.md`](../CLAUDE.md), restated here so this doc is
self-contained:

- **Mock at the `URLSessionProtocol` boundary**, not at the feature layer.
  Tests inject a `MockURLSession` that returns canned `(Data,
  URLResponse)` for each request. Don't mock `GrafanaClient` itself —
  that defeats the point of testing it.
- **Use injectable test doubles for `KeychainStore`**. The struct exposes
  read/write/delete closures so an `InMemoryKeychain` can replace the
  Security-framework backend. Do not touch the system keychain from
  tests — it's slow and leaks state across runs.
- **Use ephemeral `UserDefaults` suites** for `ServerContext` tests
  (`UserDefaults(suiteName: UUID().uuidString)`). Don't share
  `.standard` across test methods.
- **Don't test the implementation, test the contract.** A test that
  re-states the function body is noise. A test that pins the externally
  visible behavior is signal.

### What lives here

| Kind | Example |
| --- | --- |
| Codable shape | `User` decodes from a realistic `/api/user` response, including the empty-email case |
| Request construction | `getCurrentUser` sets `Authorization: Bearer …`; session-cookie credential sets `Cookie: grafana_session=…` |
| Status mapping | 401 → `.unauthorized`, 403 → `.forbidden`, 404 → `.notFound`, 5xx → `.server(status:body:)`, transport → `.transport`, JSON parse failure → `.decoding` |
| State holder behavior | `ServerContext.activate` persists to keychain + defaults; `restore` rehydrates; `signOut` clears both |
| Pure logic | `LoginView.normalizedBaseURL` accepts http(s), strips trailing slash, rejects paths and non-http schemes |

### What doesn't live here

- Real Grafana behavior. That's layer 2.
- SwiftUI rendering. XCTest can't drive a host app's view hierarchy
  reliably without a UI test target, and snapshot tests are an anti-goal
  in v1 (see below).

### Goal

`xcodebuild test` is green on `main` at all times. CI runs it on every
PR. A failure is a release blocker.

## Layer 2 — Integration tests

Future, landing in Phase 2. Design and progressive rollout in
[`12-integration-testing.md`](12-integration-testing.md).

### Why this layer exists

Unit tests pin what we *believe* Grafana does. Integration tests catch
the cases where Grafana doesn't actually do that — schema drift between
versions, the columnar `values[]` shape on `/api/ds/query`, the
`folderUIDs` vs `folderIds` rename, the two alert endpoints with
different shapes. The kind of bug that ships green unit tests and a
white screen on a real Grafana.

### How they run

- New target `GrafanaViewerIntegrationTests` (Phase 2+).
- Reads `GRAFANA_URL` + `GRAFANA_TOKEN` from `ProcessInfo.environment`
  in `setUpWithError`. If either is missing, every case calls
  `XCTSkipUnless(...)` and is *skipped*, not failed. That's what keeps
  the default `xcodebuild test` offline.
- `make integration-test` brings up the docker-compose stack, sources
  `integration/.integration-env`, runs the dedicated scheme.

### Coverage

Per docs/12's coverage-by-phase table. One or two cases per phase,
each under 30 lines, each asserting *shape* rather than specific values
(values drift between Grafana versions and across local data).

### Goal

Passes locally before any PR that touches `Networking/`, `DataSources/`,
or `Models/`. CI integration is a Phase 8 decision — until then,
local-only.

## Layer 3 — Manual simulator verification

Eyes-on-screen, on every phase's "Done when" criterion.

### Why this layer exists

SwiftUI rendering correctness, gesture handling, navigation feel, error
state visibility, dark/light mode contrast, dynamic-type behavior — none
of these are unit-testable without taking on snapshot-testing pain we've
opted out of. The cheapest catch is a human running the app.

### How to run it

```sh
make integration-up        # start Grafana, mint a service-account token
make sim                   # build + install + launch with login prefilled
# Tap Continue, walk the phase's "Done when".
make integration-down      # tear down + remove token file
```

`make sim` builds the app, boots the latest-iOS `iPhone 17` simulator
(override with `SIM_DEVICE`), installs the app, and launches it with
`GRAFANA_URL` / `GRAFANA_TOKEN` piped in as env vars. `LoginView`'s
`#if DEBUG` init reads those and prefills the form, so verification is
literally one tap on Continue. The DEBUG guard means the prefill code
is stripped from Release / TestFlight builds — no chance of shipping
hardcoded creds.

If you'd rather run from Xcode (for debugger + breakpoints), open the
project, run on the simulator, and paste the values from
`make integration-token` by hand.

### Recording the result

In the PR description, not in a committed file:

```
## Manual sim verification
- [x] Paste URL + token → "Signed in as ..." appears within 2s
- [x] Force-quit + relaunch → lands directly on SignedInView (restore works)
- [x] Tap Sign out → returns to LoginView, keychain cleared
- [ ] (anything that didn't work, with a note)
```

PR descriptions rot less than committed checklists and naturally belong
to the change being merged.

## Per-phase verification checklist

Each phase's "done" requires all three columns to be green.

| Phase | Unit additions | Integration additions | Manual sim |
| --- | --- | --- | --- |
| 0 — Foundations | 22 cases (User, GrafanaClient, ServerContext, URL norm) | — | Sign in, restore on relaunch, sign out |
| 1 — Browse | folders + search + dashboard envelope Codable; recent-dashboards persistence | — | Drill folder → dashboard → see panel placeholders |
| 2 — Render | Prometheus query envelope; `FrameDecoder` per shape | `testQueryUpShape`, `testGetKitchenSinkDashboard` | Timeseries + stat panel render with correct legends + units against live data |
| 3 — More panels | per-panel decoders (gauge, bargauge, table, logs) | + Loki query + table query | Kitchen-sink dashboard renders all six v1 panel types |
| 4 — Variables + annotations | variable substitution grammar (`:csv`, `:pipe`) | + variable query, annotation fetch | Variable change re-queries panels; annotations appear as rule marks |
| 5 — Auth completeness | cookie parsing, frontend-settings decode | + basic-auth cookie round-trip | All three auth methods land at SignedInView |
| 6 — Alerts + silences | alert + silence Codable; matcher shape | + silence create-and-expire round-trip | View firing alert, silence for 1h, see in silences list, expire from there |
| 7 — Search + starred | search response shape | + star/unstar round-trip | Search returns hits; starring a dashboard appears in Home Starred section |
| 8 — Polish + TestFlight | (no new) | (no new) | TestFlight build installs and launches on a real device; multi-server switch works |

## Anti-goals

These are deliberate non-pursuits, not omissions.

- **100% line coverage.** Lines like `case .foo: throw .foo` aren't
  worth a test each. We aim for behavior coverage, not line coverage.
- **Tests that re-state the implementation.** A test asserting "the
  function returns what the function returns" is noise. If the
  implementation is the test, delete the test.
- **SwiftUI snapshot tests in v1.** They're flaky across Xcode and SDK
  upgrades, the diff output is hard to read, and the catch rate doesn't
  justify the maintenance cost for an app this small. Revisit in v1.1+
  if rendering regressions become a recurring issue.
- **Integration tests in CI before Phase 8.** Docker on macOS GitHub
  runners is awkward, and self-hosted runners are infra we don't need
  yet. Until Phase 8, integration runs locally on the contributor's
  machine.
- **End-to-end tests through the iOS UI driving a real Grafana.** Maui
  / XCUITest can do this in theory, but the iOS-sim + docker + flaky
  layout combination is a tarpit. Manual sim verification is good
  enough for v1.

## How to run each layer

```sh
# Layer 1 — unit
xcodebuild -scheme GrafanaViewer \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# Layer 2 — integration (Phase 2+)
make integration-test

# Layer 3 — manual sim
make integration-up
make integration-token
# open Xcode, run, walk the "Done when" for the current phase
make integration-down
```

## Open question

> Do we add a `GrafanaViewerSnapshotTests` target after Phase 8 once
> the visual surface is stable?

**Probably yes, scoped tight.** The argument against snapshots in v1
(flakiness during rapid UI change) reverses once the UI stops moving.
Post-TestFlight, a small suite of "render this panel with this fixture
frame, compare to a baseline image" tests would catch panel-rendering
regressions cheaply. Defer the decision until we see what actually
regresses during the beta.

---

Onward to nothing — this is the last doc in the set. Back to
[`11-roadmap.md`](11-roadmap.md) for the implementation sequence, or
[`12-integration-testing.md`](12-integration-testing.md) for the
harness design.
