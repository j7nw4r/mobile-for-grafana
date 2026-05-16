# Claude guidance — mobile-for-grafana

## What this project is

Native iOS app (Swift / SwiftUI, iOS 17+) for read-mostly browsing of a
self-hosted Grafana OSS / Enterprise instance. Inspired by
`alexmt/mobile-for-argocd` (Expo/RN) but built from scratch in native Swift,
against a different product domain (observability viewing rather than GitOps-CD).

## Current state

**Design phase.** No Swift code yet. All design is in [`docs/`](docs/), numbered
in read-order. The implementation sequence is in
[`docs/11-roadmap.md`](docs/11-roadmap.md).

If you're picking this up:

1. Read [`docs/00-overview.md`](docs/00-overview.md) first.
2. Then [`docs/01-architecture.md`](docs/01-architecture.md).
3. Then jump to whichever doc describes the phase you're working on.

## Conventions

- **Target**: iOS 17.0+, Swift 5.10+ (commit to `@Observable` / Observation
  framework; no `ObservableObject` fallback).
- **UI**: SwiftUI only. No UIKit unless a feature genuinely requires it
  (`ASWebAuthenticationSession` is the one known exception).
- **Networking**: `URLSession` directly. No Alamofire, no async-http-client.
- **State**: `@Observable` classes injected via `.environment`. No Combine,
  no TCA, no Redux. See [`docs/01-architecture.md`](docs/01-architecture.md).
- **Persistence**: Keychain for credentials, `UserDefaults` for non-secret
  preferences (server list, recent dashboards, time-range presets). No SQLite
  / Core Data in v1.
- **Dependencies**: zero third-party Swift packages in v1. If you find
  yourself reaching for one, write a paragraph in the relevant doc justifying
  it first.
- **Tests**: XCTest for unit tests; mock the network layer at the `URLSession`
  protocol boundary, not at the feature layer.

## Code style

- Prefer `struct` over `class` for models. Use `class` only for `@Observable`
  state holders and reference-semantics needs.
- Don't write doc comments on obvious code. Do write them on public API of
  the `Networking` and `DataSources` modules — they're the contract surface
  between layers.
- Don't add error handling for cases that can't happen. Trust internal
  contracts; validate only at boundaries (network, user input, Keychain).
- Match Grafana's terminology in identifiers (`folderUID`, not `folderID`;
  `refId`, not `referenceId`; `panel`, not `chart`).

## Grafana API quirks to remember

- Search filtering uses `folderUIDs` (plural, UID-based), not `folderIds`
  in Grafana 10+.
- `/api/ds/query` returns Arrow-style columnar frames — see
  [`docs/04-datasource-queries.md`](docs/04-datasource-queries.md).
- Two alert listing endpoints: `/api/prometheus/grafana/api/v1/alerts` (rule
  engine state) vs `/api/alertmanager/grafana/api/v2/alerts` (notification
  pipeline). They are not interchangeable — see
  [`docs/07-alerts.md`](docs/07-alerts.md).
- There is **no "acknowledge"** in Grafana alerting. Ack-style UX = short
  silence.
- Grafana mobile OIDC has no PKCE path. We harvest the `grafana_session`
  cookie from `ASWebAuthenticationSession`. Background in
  [`docs/02-auth.md`](docs/02-auth.md).

## When in doubt

The 13 docs are the source of truth. If an implementation detail isn't in a
doc, that's a gap — surface it before coding around it.
