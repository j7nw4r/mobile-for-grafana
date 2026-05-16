import Foundation

/// `/api/user` response. Used during login + cold launch to validate the
/// stored credential.
struct User: Sendable, Decodable, Hashable {
    let id: Int
    let login: String
    let email: String
    let name: String
    let isGrafanaAdmin: Bool
    let orgId: Int
}
