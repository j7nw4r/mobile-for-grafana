# 12 — Integration testing against a real Grafana

This doc is forward-looking. Nothing here is implemented until Phase 2 of
[`11-roadmap.md`](11-roadmap.md). It exists now so the design is fixed
before we start writing the harness.

## Why this exists

The unit suite in `GrafanaViewerTests` mocks the network at the
`URLSessionProtocol` boundary. That's the right default per
[`CLAUDE.md`](../CLAUDE.md) and it covers Codable shape, error mapping,
and request construction. What it doesn't cover:

- **API quirks** of the kind already called out in `CLAUDE.md`:
  `folderUIDs` vs `folderIds`, unix-ms-as-string in `/api/ds/query`, two
  alert endpoints with different shapes, the columnar `values[]` layout.
  Mocks encode what we *believe* the API does. We want a check on what it
  actually does.
- **Schema drift** between supported Grafana versions (10.x and 11.x).
- **Behaviors that are awkward to mock faithfully**: a query response with
  `error` set on one refId and `frames` set on another; an empty result;
  a `Set-Cookie` from `/api/login` with whatever attributes Grafana
  actually emits.

A live suite running a known-version Grafana + Prometheus is cheap
insurance against the failure mode where unit tests stay green but the
app breaks on real Grafanas.

## Why not Testcontainers-for-Swift

There is a community `testcontainers-swift`. We are not using it:

- Pre-1.0, single-maintainer, thin coverage.
- Violates the "zero third-party Swift packages in v1" rule in
  [`01-architecture.md`](01-architecture.md).
- The capability it provides (declarative container lifecycle inside
  XCTest) we can replicate with a shell script and a few env vars.

We do conceptually the same thing Testcontainers does — start containers,
wait for healthy, run tests, tear down — orchestrated by a `Makefile`
and a small shell script instead of a Swift library.

## Stack

`integration/docker-compose.yml` brings up two services:

| Service | Image | Host port | Notes |
| --- | --- | --- | --- |
| `grafana` | `grafana/grafana-oss:11.2.0` | `3000` | Pinned, not floating tag. |
| `prometheus` | `prom/prometheus:v2.54.1` | `9090` | Scrapes itself so `up{}` is always populated. |

iOS Simulator shares the host's loopback, so tests point at
`http://localhost:3000` from the same machine that runs `docker compose
up`. No bridge networking or DNS gymnastics.

Versions are pinned exactly, not floating. We bump deliberately. A failed
integration run after a bump tells us what changed between Grafana
versions, which is half the point of having the suite.

### Provisioning

Grafana is preconfigured via files mounted into `/etc/grafana/provisioning`:

```
integration/provisioning/
  datasources/
    prometheus.yaml          # points at http://prometheus:9090
  dashboards/
    dashboards.yaml          # provider config: load *.json from this dir
    kitchen-sink.json        # the fixture dashboard
  alerting/
    rules.yaml               # (Phase 6) one always-firing rule
    contact-points.yaml      # (Phase 6) a no-op email contact
```

The kitchen-sink dashboard has one panel of each v1 type, all backed by
the provisioned Prometheus datasource. Panel queries are intentionally
trivial (`up`, `count(up)`, …) so the test asserts the *shape* of the
response, not specific numerical values that drift between runs.

The dashboard JSON lives in the repo. Reviewable, reproducible, and
diff-able. We considered creating it via API in test setup; that
optimizes for nothing and trades a static file for runtime state.

## Service-account token bootstrap

Grafana has no "provision a token from disk" feature — service-account
tokens are minted at runtime. The bootstrap runs after Grafana reports
healthy:

```
1. GET  /api/health                                        until 200
2. POST /api/serviceaccounts                  (basic auth) → { id }
3. POST /api/serviceaccounts/{id}/tokens      (basic auth) → { key }
4. write key to integration/.integration-env              (chmod 0600)
```

It's idempotent: a 409 on step 2 means the account exists already, in
which case we DELETE existing tokens for that account and re-mint
(step 3 + 4). Tokens leak into shell history less often than passwords;
rotating on every `make integration-up` keeps the leak window small.

Admin basic-auth credentials come from the compose file
(`GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD`). They're fine
to commit — this is a fresh container with no real data in it. The
*token* is the secret, and it lives in `.integration-env`, which is
gitignored.

## Make targets

A root-level `Makefile` (or shell scripts under `integration/scripts/`)
exposes:

| Target | What it does |
| --- | --- |
| `make integration-up` | `docker compose up -d`, wait for `/api/health`, bootstrap token, write `.integration-env`. |
| `make integration-test` | `integration-up` + `xcodebuild test` on the integration scheme with env vars sourced from `.integration-env`. |
| `make integration-down` | `docker compose down -v` + `rm -f integration/.integration-env`. |
| `make integration-logs` | `docker compose logs -f grafana prometheus`. |

Wait-for-healthy has a 90s budget. Cold-pulling `grafana-oss:11.2.0` on
a fresh machine can take 30s on its own, and Grafana itself takes
~10s to be ready to mint tokens.

## Test target

A new XCTest target, separate from the unit suite:

```
GrafanaViewer/GrafanaViewerIntegrationTests/
  Helpers/
    IntegrationEnvironment.swift     # reads + validates GRAFANA_URL / GRAFANA_TOKEN
    LiveClient.swift                 # GrafanaClient factory pointing at the live stack
  Phase2/
    QueryDatasourceTests.swift
  Phase3/                            # added when Phase 3 starts
    LokiQueryTests.swift
  …
```

`IntegrationEnvironment` reads `GRAFANA_URL` and `GRAFANA_TOKEN` from
`ProcessInfo.processInfo.environment`. If either is missing, every test
in the target calls `try XCTSkipUnless(...)` in `setUpWithError` and is
*skipped*, not failed.

This is the part that makes the suite opt-in. A contributor who runs
`xcodebuild test` on the default `GrafanaViewer` scheme gets the unit
suite (offline, fast, deterministic). To exercise the integration suite,
they invoke the dedicated scheme via `make integration-test`, which
populates the env.

### Scheme

A new `GrafanaViewerIntegration` scheme runs only the
`GrafanaViewerIntegrationTests` target. This keeps the main scheme's
test-action fast and makes it easy for CI to opt in or out by
scheme name.

## Coverage by phase

Each phase adds one or two tests. The suite grows with the app rather
than landing all at once.

| Phase | New cases | What they check |
| --- | --- | --- |
| 2 | `testQueryUpReturnsTimeSeriesShape`, `testGetKitchenSinkDashboard` | `/api/ds/query` columnar `values[]`, refId routing; `DashboardEnvelope` decodes a real provisioned dashboard. |
| 3 | `testTableQueryReturnsRows`, `testLogsQueryShape` | Loki added to compose; Loki frame shape; table frame shape. |
| 4 | `testVariableQueryReturnsValues`, `testAnnotationFetch` | `query`-type variable executes; `/api/annotations` returns the shape we model. |
| 5 | `testBasicAuthLoginReturnsCookie` | Real `Set-Cookie: grafana_session=…` attributes; cookie-credential round-trip. |
| 6 | `testCreateSilenceAndExpire` | Full Alertmanager v2 silence round-trip against Grafana's bundled Alertmanager. |
| 7 | `testStarUnstarRoundTrip` | `POST /api/user/stars/...` is reflected in `/api/search?starred=true`. |

Each test stays small (target: under 30 lines). They assert the *shape*
we model, not specific values that drift between Grafana versions. If
Grafana 11.3 renames a field, we want to find out from a failing test
diff that points right at the field — not from twenty cascading
assertions about specific numbers.

## CI

Phase 8's CI design ([`10-build-and-release.md`](10-build-and-release.md))
runs unit tests on every PR via `xcodebuild ... test` on the default
scheme. Integration tests are a separate workflow with a different
trigger:

- **Trigger**: PRs that touch `Networking/`, `DataSources/`, or
  `Models/`. PRs touching only `Panels/`, `Theme/`, or `docs/` skip
  integration to keep the median PR fast.
- **Runner**: not GitHub-hosted macOS (no Docker). Options when we get
  here: a self-hosted macOS runner with Docker, or a Linux runner using
  a no-simulator XCTest harness. We will pick one in Phase 8 when the
  suite shape is known.
- **Until then**: integration is local-only. The Phase 2 deliverable is
  that the suite *runs* and passes locally — not that it runs in CI.

## Failure modes to design for

- **Container crash mid-test.** Tests must not hang. `URLSession`'s
  default timeout is 60s; integration tests override to 5s via
  `URLSessionConfiguration.timeoutIntervalForRequest`. A crashed Grafana
  surfaces as a fast transport error, not a 60s wait.
- **Slow first boot.** Cold-pull of `grafana-oss:11.2.0` is ~30s.
  `integration-up`'s wait-for-healthy budget is 90s. CI runs will
  pre-pull the image as a separate step when we get there.
- **Token leak.** `.integration-env` is gitignored. The bootstrap writes
  with mode `0600`. Tokens rotate on every `integration-up`. Tokens are
  scoped to Viewer role unless a specific test needs Editor (silence
  tests in Phase 6) — see role table below.
- **Port collisions.** Compose binds 3000 and 9090. Developers with
  conflicts override via `GRAFANA_HOST_PORT` / `PROMETHEUS_HOST_PORT`
  env vars in compose, and adjust `GRAFANA_URL` accordingly.

### Token roles per phase

| Phase | Role | Why |
| --- | --- | --- |
| 2–5, 7 | Viewer | Read-only API surface. |
| 6 | Editor | Silence create/expire requires write. |

Distinct service accounts per role; the bootstrap mints both when Phase
6 lands.

## Files this introduces

When the harness is implemented in Phase 2:

```
Makefile                                          (or scripts/ at repo root)
.gitignore                                       += integration/.integration-env
integration/
  docker-compose.yml
  provisioning/
    datasources/prometheus.yaml
    dashboards/dashboards.yaml
    dashboards/kitchen-sink.json
  scripts/
    bootstrap-token.sh
    wait-for-healthy.sh
GrafanaViewer/GrafanaViewerIntegrationTests/
  Info.plist
  Helpers/
    IntegrationEnvironment.swift
    LiveClient.swift
  Phase2/
    QueryDatasourceTests.swift
    DashboardEnvelopeTests.swift
```

None of this exists yet. Phase 2 lands the Phase 2 row; subsequent
phases add their rows.

## Open questions

> Should the kitchen-sink dashboard live in the repo (provisioned at boot)
> or be created via API at test setup?

**In the repo, provisioned at boot.** A JSON file in git is reviewable
and reproducible; API-created fixtures get rebuilt each run and drift
from what tests assume. The cost is that adding a panel to the fixture
requires editing JSON by hand — acceptable for a fixture that changes
rarely.

> Loki container in Phase 3, or stub Loki against the TestData datasource?

**Real Loki container in Phase 3.** The Loki query envelope and the logs
frame shape are different enough from Prometheus that stubbing against
TestData would teach us nothing about Loki. Adding `grafana/loki:3.x` to
compose when Phase 3 begins is the right move.

> Separate Alertmanager container for silence tests in Phase 6?

**No — use the Grafana-bundled Alertmanager.** Grafana ships one for
`grafana`-managed alerts, accessed via
`/api/alertmanager/grafana/...`. That's the only Alertmanager our app
talks to, so it's the only one we should test against.

> OIDC tests in Phase 5?

**Punt.** The OIDC cookie-harvest flow involves a `WKWebView` and a real
identity provider. Standing up a Dex (or Keycloak) container plus a
provisioned OIDC client in Grafana, *plus* driving the WKWebView in a
test, is a significant addition. We'll cover OIDC manually against a
real provider during Phase 5 development and add automation only if it
proves flaky in practice.

---

Onward (or rather, back): [`11-roadmap.md`](11-roadmap.md) for where this
fits in the sequence.
