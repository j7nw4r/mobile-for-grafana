import Foundation
import Observation
import OSLog

/// App-level state holder: which server is active, its credential, and the
/// `GrafanaClient` built from those. The only state holder that crosses
/// feature boundaries — per-feature models are scoped to their view tree.
///
/// Replacing the active server tears down dependent views, which throws away
/// per-feature models. That is intentional: a server switch should reload the
/// dashboard list, alert list, etc.
@MainActor
@Observable
final class ServerContext {
    struct ActiveServer {
        let url: URL
        let credential: Credential
        let client: GrafanaClient
    }

    var activeServer: ActiveServer?
    var knownServers: [URL]

    private let keychain: KeychainStore
    private let defaults: UserDefaults

    init(keychain: KeychainStore = .live, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
        self.knownServers = Self.loadKnownServers(defaults: defaults)
    }

    /// Promote a (URL, credential) pair to the active server. Persists the
    /// credential to Keychain (keyed by host) and records the URL in
    /// `UserDefaults`. Caller is responsible for having validated the
    /// credential against `/api/user` first.
    func activate(serverURL: URL, credential: Credential) throws {
        guard let host = serverURL.host(), !host.isEmpty else {
            throw ServerContextError.urlMissingHost
        }
        try keychain.write(host, credential)
        let client = GrafanaClient(baseURL: serverURL, credential: credential)
        activeServer = ActiveServer(url: serverURL, credential: credential, client: client)
        rememberServer(serverURL)
    }

    /// Reload the last-used server from `UserDefaults` + Keychain. Best-effort:
    /// if anything is missing or the Keychain read fails, leaves
    /// `activeServer` nil so the UI falls back to `LoginView`.
    ///
    /// Does not validate the credential against the server — that happens
    /// lazily on the next API call. A bad/expired credential surfaces as a
    /// 401 there and the feature signs the user out.
    func restore() {
        guard let stored = defaults.string(forKey: Self.lastUsedServerKey),
              let url = URL(string: stored),
              let host = url.host(), !host.isEmpty
        else { return }
        do {
            guard let credential = try keychain.read(host) else { return }
            let client = GrafanaClient(baseURL: url, credential: credential)
            activeServer = ActiveServer(url: url, credential: credential, client: client)
        } catch {
            AppLog.auth.error("restore failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Clear the active server and delete its Keychain credential. The host
    /// is retained in `knownServers` so the user can re-sign-in without
    /// retyping the URL — use `forget(serverURL:)` to drop it entirely.
    func signOut() {
        if let active = activeServer, let host = active.url.host() {
            try? keychain.delete(host)
        }
        activeServer = nil
        defaults.removeObject(forKey: Self.lastUsedServerKey)
    }

    private func rememberServer(_ url: URL) {
        if !knownServers.contains(url) {
            knownServers.append(url)
            defaults.set(knownServers.map(\.absoluteString), forKey: Self.knownServersKey)
        }
        defaults.set(url.absoluteString, forKey: Self.lastUsedServerKey)
    }

    private static func loadKnownServers(defaults: UserDefaults) -> [URL] {
        let raw = defaults.stringArray(forKey: knownServersKey) ?? []
        return raw.compactMap(URL.init(string:))
    }

    private static let knownServersKey = "knownServers"
    private static let lastUsedServerKey = "lastUsedServer"
}

enum ServerContextError: Error {
    case urlMissingHost
}
