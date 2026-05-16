import Foundation

/// One-method seam over `URLSession` so tests can inject canned responses.
/// Production code passes `URLSession.shared`; tests pass a fake.
protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}
