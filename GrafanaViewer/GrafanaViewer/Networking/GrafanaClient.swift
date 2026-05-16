import Foundation
import OSLog

/// Wraps `URLSession` with the active server's base URL and credential.
///
/// Builds authenticated requests, decodes JSON into `Models/` types, and maps
/// non-2xx responses to `GrafanaError`. It does not cache, retry, or mutate
/// application state — feature code is responsible for surfacing errors.
struct GrafanaClient: Sendable {
    let baseURL: URL
    let credential: Credential
    private let session: URLSessionProtocol
    private let decoder: JSONDecoder

    init(
        baseURL: URL,
        credential: Credential,
        session: URLSessionProtocol = URLSession.shared,
        decoder: JSONDecoder = .grafana
    ) {
        self.baseURL = baseURL
        self.credential = credential
        self.session = session
        self.decoder = decoder
    }

    /// Fetch the user the active credential resolves to. Used by the login
    /// flow to validate a newly entered token, and by `SignedInView` to
    /// re-validate on launch.
    func getCurrentUser() async throws -> User {
        try await get("/api/user")
    }

    /// Issue a `GET` against an API path (e.g. `"/api/folders"`).
    func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as: Response.Type = Response.self
    ) async throws -> Response {
        let request = try buildRequest(method: "GET", path: path, query: query, body: nil)
        return try await perform(request)
    }

    /// Issue a `POST` with a JSON body.
    func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        as: Response.Type = Response.self
    ) async throws -> Response {
        let encoded = try JSONEncoder().encode(body)
        let request = try buildRequest(method: "POST", path: path, query: [], body: encoded)
        return try await perform(request)
    }

    private func buildRequest(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Data?
    ) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GrafanaError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let finalURL = components.url else { throw GrafanaError.invalidResponse }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        switch credential {
        case .bearerToken(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .sessionCookie(let cookie):
            request.setValue("grafana_session=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            AppLog.network.error("transport error: \(urlError.localizedDescription, privacy: .public)")
            throw GrafanaError.transport(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GrafanaError.invalidResponse
        }

        switch http.statusCode {
        case 200..<300: break
        case 401: throw GrafanaError.unauthorized
        case 403: throw GrafanaError.forbidden
        case 404: throw GrafanaError.notFound
        default: throw GrafanaError.server(status: http.statusCode, body: data)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch let decodingError as DecodingError {
            AppLog.network.error("decoding error: \(String(describing: decodingError), privacy: .public)")
            throw GrafanaError.decoding(decodingError)
        }
    }
}

extension JSONDecoder {
    static var grafana: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
