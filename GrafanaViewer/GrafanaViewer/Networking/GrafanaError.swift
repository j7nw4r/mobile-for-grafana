import Foundation

/// All `GrafanaClient` failure modes. Features surface these directly — the
/// client does not retry.
enum GrafanaError: Error, Sendable {
    case unauthorized
    case forbidden
    case notFound
    case server(status: Int, body: Data)
    case transport(URLError)
    case decoding(DecodingError)
    case invalidResponse
}
