# Mobile for Grafana

A native iOS app (Swift / SwiftUI) for browsing a self-hosted Grafana OSS or
Enterprise instance from your phone. Read-mostly: dashboards, panels, alerts,
silences, search, starred, annotations. Panels render natively via Swift Charts —
no server-side image renderer required.

Status: **design phase**. The implementation is sequenced in
[`docs/11-roadmap.md`](docs/11-roadmap.md); no Swift code has landed yet.

## Documents

The design lives under [`docs/`](docs/) and is meant to be read in order:

| # | Doc | Topic |
| --- | --- | --- |
| 00 | [overview](docs/00-overview.md) | Vision, scope, non-goals, glossary |
| 01 | [architecture](docs/01-architecture.md) | Modules, state management, frameworks |
| 02 | [auth](docs/02-auth.md) | Token, basic, and OIDC-cookie-harvest flows |
| 03 | [api-and-models](docs/03-api-and-models.md) | Grafana endpoints + Swift Codable types |
| 04 | [datasource-queries](docs/04-datasource-queries.md) | `/api/ds/query` envelope, Prometheus & Loki |
| 05 | [panels-and-charts](docs/05-panels-and-charts.md) | Panel types → Swift Charts mapping |
| 06 | [dashboards-and-variables](docs/06-dashboards-and-variables.md) | Folder browsing, variables, time range |
| 07 | [alerts](docs/07-alerts.md) | Alert listing + silence flow |
| 08 | [search-starred-annotations](docs/08-search-starred-annotations.md) | Smaller features |
| 09 | [ui-screens](docs/09-ui-screens.md) | Screen-by-screen wireframes |
| 10 | [build-and-release](docs/10-build-and-release.md) | Xcode config, signing, TestFlight |
| 11 | [roadmap](docs/11-roadmap.md) | 8-phase implementation order |

## Inspiration

Product shape is inspired by [`alexmt/mobile-for-argocd`](https://github.com/alexmt/mobile-for-argocd)
(an Expo/React Native app for ArgoCD). This project is a fresh native-Swift
implementation aimed at a different domain — see
[`docs/00-overview.md`](docs/00-overview.md) for what carries over and what
doesn't.

## License

TBD.
