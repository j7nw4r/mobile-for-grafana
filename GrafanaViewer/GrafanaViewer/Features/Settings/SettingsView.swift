import SwiftUI
import OSLog

/// Phase 1 minimum: current server + signed-in user + sign-out. The
/// full Settings spec (multi-server, silences, diagnostics, about) lands
/// in later phases as the underlying features arrive.
struct SettingsView: View {
    @Environment(ServerContext.self) private var session

    @State private var user: User?
    @State private var refreshFailed = false

    var body: some View {
        NavigationStack {
            List {
                Section("Current server") {
                    if let url = session.activeServer?.url {
                        Label(url.host() ?? url.absoluteString, systemImage: "server.rack")
                        Text(url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let user {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name)
                            Text(user.email.isEmpty ? user.login : user.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack { ProgressView(); Text("Loading user…").foregroundStyle(.secondary) }
                    }
                    if refreshFailed {
                        Label("Couldn't refresh user info", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        session.signOut()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .task(id: session.activeServer?.url) { await refreshUser() }
        }
    }

    private func refreshUser() async {
        guard let client = session.activeServer?.client else { return }
        do {
            user = try await client.getCurrentUser()
            refreshFailed = false
        } catch GrafanaError.unauthorized {
            session.signOut()
        } catch {
            AppLog.app.error("user refresh failed: \(String(describing: error), privacy: .public)")
            refreshFailed = true
        }
    }
}
