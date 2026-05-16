import Foundation

/// How `GrafanaClient` authenticates a request.
///
/// - `bearerToken`: a Grafana service-account token or API key. Sent as
///   `Authorization: Bearer <token>`.
/// - `sessionCookie`: the `grafana_session` value harvested from the OIDC
///   flow. Sent as `Cookie: grafana_session=<value>`.
enum Credential: Sendable, Hashable {
    case bearerToken(String)
    case sessionCookie(String)
}
