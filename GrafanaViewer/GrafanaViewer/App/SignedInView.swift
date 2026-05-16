import SwiftUI
import OSLog

/// Phase-0 placeholder: shows the signed-in user's name and a sign-out
/// button. Replaced by the TabView in Phase 1.
struct SignedInView: View {
    @Environment(ServerContext.self) private var session

    @State private var user: User?
    @State private var loadError: LoginError?

    var body: some View {
        NavigationStack {
            Group {
                if let user {
                    signedInContent(user: user)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't load your account", systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text(loadError.message)
                    } actions: {
                        Button("Sign out") { session.signOut() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView("Loading…")
                }
            }
            .navigationTitle("Signed in")
            .task(id: session.activeServer?.url) { await load() }
        }
    }

    @ViewBuilder
    private func signedInContent(user: User) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Signed in as \(user.name) (\(user.email))")
                .font(.headline)
                .multilineTextAlignment(.center)
            if let url = session.activeServer?.url {
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign out", role: .destructive) {
                session.signOut()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private func load() async {
        guard let client = session.activeServer?.client else { return }
        user = nil
        loadError = nil
        do {
            user = try await client.getCurrentUser()
        } catch let err as GrafanaError {
            loadError = .from(err)
            if case .unauthorized = err {
                session.signOut()
            }
        } catch {
            AppLog.app.error("user load failed: \(String(describing: error), privacy: .public)")
            loadError = .unknown
        }
    }
}
