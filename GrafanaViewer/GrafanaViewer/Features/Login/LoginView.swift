import SwiftUI
import OSLog

struct LoginView: View {
    @Environment(ServerContext.self) private var session

    @State private var serverURL: String = ""
    @State private var token: String = ""
    @State private var error: LoginError?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://grafana.example.com", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.next)
                }

                Section("Service-account token") {
                    SecureField("glsa_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { Task { await submit() } }
                }

                if let error {
                    Section {
                        Label(error.message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: { Task { await submit() } }) {
                        if isSubmitting {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Continue").frame(maxWidth: .infinity).bold()
                        }
                    }
                    .disabled(isSubmitting || !canSubmit)
                }
            }
            .navigationTitle("Sign in to Grafana")
            .disabled(isSubmitting)
        }
    }

    private var canSubmit: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty &&
            !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() async {
        error = nil
        guard let url = Self.normalizedBaseURL(serverURL) else {
            error = .invalidURL
            return
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespaces)
        let credential = Credential.bearerToken(trimmedToken)
        let probe = GrafanaClient(baseURL: url, credential: credential)

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await probe.getCurrentUser()
            try session.activate(serverURL: url, credential: credential)
        } catch let err as GrafanaError {
            error = LoginError.from(err)
        } catch {
            AppLog.auth.error("login failed: \(String(describing: error), privacy: .public)")
            self.error = .unknown
        }
    }

    static func normalizedBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        // docs/02 — "Validate URL format (http:// or https://, no path)".
        // Accept a bare "/" as no-path; reject anything deeper. Then strip
        // it so the stored base URL has no trailing slash.
        let path = components.path
        guard path.isEmpty || path == "/" else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.scheme = scheme
        return components.url
    }
}

enum LoginError: Equatable {
    case invalidURL
    case unauthorized
    case forbidden
    case notFound
    case network
    case server
    case unknown

    var message: String {
        switch self {
        case .invalidURL:
            return "Enter a valid http(s) URL — e.g. https://grafana.example.com"
        case .unauthorized:
            return "Token is invalid or expired."
        case .forbidden:
            return "Token works but has no permissions."
        case .notFound:
            return "Server URL did not respond — check the URL."
        case .network:
            return "Could not reach the server. Check your connection and try again."
        case .server:
            return "The server returned an unexpected response."
        case .unknown:
            return "Could not sign in."
        }
    }

    static func from(_ err: GrafanaError) -> LoginError {
        switch err {
        case .unauthorized: return .unauthorized
        case .forbidden: return .forbidden
        case .notFound: return .notFound
        case .transport: return .network
        case .server, .invalidResponse, .decoding: return .server
        }
    }
}
