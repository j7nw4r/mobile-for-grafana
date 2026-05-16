import XCTest
@testable import GrafanaViewer

final class UserDecodingTests: XCTestCase {
    func testDecodesRealisticUserJSON() throws {
        let json = """
        {
          "id": 1,
          "email": "alice@example.com",
          "name": "Alice",
          "login": "alice",
          "theme": "",
          "orgId": 1,
          "isGrafanaAdmin": true,
          "isDisabled": false,
          "isExternal": false
        }
        """.data(using: .utf8)!

        let user = try JSONDecoder().decode(User.self, from: json)
        XCTAssertEqual(user.id, 1)
        XCTAssertEqual(user.login, "alice")
        XCTAssertEqual(user.email, "alice@example.com")
        XCTAssertEqual(user.name, "Alice")
        XCTAssertEqual(user.orgId, 1)
        XCTAssertTrue(user.isGrafanaAdmin)
    }

    func testEmptyEmailIsAllowed() throws {
        let json = """
        {"id":2,"email":"","name":"Bob","login":"bob","orgId":1,"isGrafanaAdmin":false}
        """.data(using: .utf8)!
        let user = try JSONDecoder().decode(User.self, from: json)
        XCTAssertEqual(user.email, "")
    }
}

final class GrafanaClientTests: XCTestCase {
    private let baseURL = URL(string: "https://grafana.example.com")!

    func testGetCurrentUserSetsBearerHeaderAndDecodes() async throws {
        let session = MockURLSession { request in
            XCTAssertEqual(request.url?.path, "/api/user")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer glsa_secret")
            XCTAssertEqual(request.httpMethod, "GET")
            let body = #"{"id":1,"email":"a@x","name":"A","login":"a","orgId":1,"isGrafanaAdmin":false}"#
            return (Data(body.utf8), Self.response(status: 200))
        }
        let client = GrafanaClient(baseURL: baseURL, credential: .bearerToken("glsa_secret"), session: session)
        let user = try await client.getCurrentUser()
        XCTAssertEqual(user.login, "a")
    }

    func testSessionCookieCredentialSetsCookieHeader() async throws {
        let session = MockURLSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "grafana_session=cookie_value")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = #"{"id":1,"email":"a@x","name":"A","login":"a","orgId":1,"isGrafanaAdmin":false}"#
            return (Data(body.utf8), Self.response(status: 200))
        }
        let client = GrafanaClient(baseURL: baseURL, credential: .sessionCookie("cookie_value"), session: session)
        _ = try await client.getCurrentUser()
    }

    func testStatusMapping() async {
        for (status, expected): (Int, GrafanaError) in [
            (401, .unauthorized),
            (403, .forbidden),
            (404, .notFound),
        ] {
            let session = MockURLSession { _ in (Data(), Self.response(status: status)) }
            let client = GrafanaClient(baseURL: baseURL, credential: .bearerToken("t"), session: session)
            do {
                _ = try await client.getCurrentUser()
                XCTFail("expected error for status \(status)")
            } catch let err as GrafanaError {
                XCTAssertEqual(err.kindLabel, expected.kindLabel, "status \(status)")
            } catch {
                XCTFail("unexpected error type for status \(status): \(error)")
            }
        }
    }

    func testServerErrorMapsToServerCase() async {
        let session = MockURLSession { _ in (Data("boom".utf8), Self.response(status: 500)) }
        let client = GrafanaClient(baseURL: baseURL, credential: .bearerToken("t"), session: session)
        do {
            _ = try await client.getCurrentUser()
            XCTFail("expected error")
        } catch let GrafanaError.server(status, body) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, Data("boom".utf8))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDecodingFailureMapsToDecodingCase() async {
        let session = MockURLSession { _ in (Data("not json".utf8), Self.response(status: 200)) }
        let client = GrafanaClient(baseURL: baseURL, credential: .bearerToken("t"), session: session)
        do {
            _ = try await client.getCurrentUser()
            XCTFail("expected error")
        } catch GrafanaError.decoding {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://grafana.example.com/api/user")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

@MainActor
final class ServerContextTests: XCTestCase {
    func testActivatePersistsCredentialAndDefaults() throws {
        let store = InMemoryKeychain()
        let defaults = ephemeralDefaults()
        let ctx = ServerContext(keychain: store.keychainStore, defaults: defaults)

        let url = URL(string: "https://grafana.example.com")!
        try ctx.activate(serverURL: url, credential: .bearerToken("glsa_abc"))

        XCTAssertEqual(ctx.activeServer?.url, url)
        XCTAssertEqual(store.items["grafana.example.com"], .bearerToken("glsa_abc"))
        XCTAssertEqual(defaults.string(forKey: "lastUsedServer"), url.absoluteString)
        XCTAssertEqual(defaults.stringArray(forKey: "knownServers"), [url.absoluteString])
    }

    func testRestoreRehydratesActiveServer() throws {
        let store = InMemoryKeychain()
        let defaults = ephemeralDefaults()
        let url = URL(string: "https://grafana.example.com")!
        try store.keychainStore.write("grafana.example.com", .bearerToken("glsa_xyz"))
        defaults.set(url.absoluteString, forKey: "lastUsedServer")
        defaults.set([url.absoluteString], forKey: "knownServers")

        let ctx = ServerContext(keychain: store.keychainStore, defaults: defaults)
        ctx.restore()

        XCTAssertEqual(ctx.activeServer?.url, url)
        XCTAssertEqual(ctx.activeServer?.credential, .bearerToken("glsa_xyz"))
    }

    func testRestoreWithNoLastUsedIsNoop() {
        let store = InMemoryKeychain()
        let defaults = ephemeralDefaults()
        let ctx = ServerContext(keychain: store.keychainStore, defaults: defaults)
        ctx.restore()
        XCTAssertNil(ctx.activeServer)
    }

    func testSignOutClearsActiveAndDeletesKeychain() throws {
        let store = InMemoryKeychain()
        let defaults = ephemeralDefaults()
        let ctx = ServerContext(keychain: store.keychainStore, defaults: defaults)
        let url = URL(string: "https://grafana.example.com")!
        try ctx.activate(serverURL: url, credential: .bearerToken("glsa_abc"))

        ctx.signOut()

        XCTAssertNil(ctx.activeServer)
        XCTAssertNil(store.items["grafana.example.com"])
        XCTAssertNil(defaults.string(forKey: "lastUsedServer"))
    }

    func testActivateRejectsURLWithoutHost() {
        let store = InMemoryKeychain()
        let defaults = ephemeralDefaults()
        let ctx = ServerContext(keychain: store.keychainStore, defaults: defaults)
        let url = URL(string: "https:///")!
        XCTAssertThrowsError(try ctx.activate(serverURL: url, credential: .bearerToken("t")))
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

@MainActor
final class LoginURLNormalizationTests: XCTestCase {
    func testAcceptsBareHTTPS() {
        let url = LoginView.normalizedBaseURL("https://grafana.example.com")
        XCTAssertEqual(url?.absoluteString, "https://grafana.example.com")
    }

    func testAcceptsTrailingSlashAndStripsIt() {
        let url = LoginView.normalizedBaseURL("https://grafana.example.com/")
        XCTAssertEqual(url?.absoluteString, "https://grafana.example.com")
    }

    func testTrimsWhitespace() {
        let url = LoginView.normalizedBaseURL("  https://grafana.example.com  ")
        XCTAssertEqual(url?.absoluteString, "https://grafana.example.com")
    }

    func testRejectsHTTPWithPath() {
        XCTAssertNil(LoginView.normalizedBaseURL("https://grafana.example.com/grafana"))
    }

    func testRejectsNonHTTPScheme() {
        XCTAssertNil(LoginView.normalizedBaseURL("ftp://grafana.example.com"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(LoginView.normalizedBaseURL(""))
        XCTAssertNil(LoginView.normalizedBaseURL("   "))
    }

    func testRejectsMissingHost() {
        XCTAssertNil(LoginView.normalizedBaseURL("https://"))
    }
}

// MARK: - Test doubles

struct MockURLSession: URLSessionProtocol {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

/// In-memory `KeychainStore` backing for tests — avoids touching the real
/// system keychain (which is slow + leaks state across runs).
final class InMemoryKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String: Credential] = [:]

    var items: [String: Credential] {
        lock.lock(); defer { lock.unlock() }
        return _items
    }

    var keychainStore: KeychainStore {
        KeychainStore(
            read: { [weak self] host in
                guard let self else { return nil }
                self.lock.lock(); defer { self.lock.unlock() }
                return self._items[host]
            },
            write: { [weak self] host, credential in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                self._items[host] = credential
            },
            delete: { [weak self] host in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                self._items.removeValue(forKey: host)
            }
        )
    }
}

// MARK: - GrafanaError comparison helper (avoids equating associated values)

extension GrafanaError {
    fileprivate var kindLabel: String {
        switch self {
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .notFound: return "notFound"
        case .server: return "server"
        case .transport: return "transport"
        case .decoding: return "decoding"
        case .invalidResponse: return "invalidResponse"
        }
    }
}
