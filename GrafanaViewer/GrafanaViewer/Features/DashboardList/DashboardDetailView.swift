import SwiftUI
import OSLog

/// Phase 1 shell: shows the dashboard's title, panel count, and a card
/// per panel with "Panel rendering coming in Phase 2" placeholder copy.
/// Phase 2 replaces the placeholder cards with real panel renderers.
struct DashboardDetailView: View {
    @Environment(ServerContext.self) private var session
    @Environment(RecentDashboardsStore.self) private var recentStore

    let uid: String
    let navTitle: String

    @State private var envelope: DashboardEnvelope?
    @State private var loadError: GrafanaError?
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    HStack { ProgressView(); Text("Loading dashboard…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't load dashboard", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message(for: loadError))
                    } actions: {
                        Button("Retry") { Task { await load() } }.buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 40)
                } else if let envelope {
                    loadedContent(envelope: envelope)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func loadedContent(envelope: DashboardEnvelope) -> some View {
        let dash = envelope.dashboard
        VStack(alignment: .leading, spacing: 8) {
            Text(dash.title).font(.title2).bold()
            HStack(spacing: 8) {
                Label("\(dash.panels.count) panel\(dash.panels.count == 1 ? "" : "s")", systemImage: "rectangle.split.3x1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let folderTitle = envelope.meta.folderTitle {
                    Text("·").foregroundStyle(.secondary)
                    Label(folderTitle, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)

        if dash.panels.isEmpty {
            ContentUnavailableView("Empty dashboard", systemImage: "rectangle.dashed",
                description: Text("This dashboard has no panels."))
                .padding(.top, 40)
        } else {
            ForEach(dash.panels) { panel in
                PanelPlaceholderCard(panel: panel)
            }
        }
    }

    private func load() async {
        guard let client = session.activeServer?.client else { return }
        isLoading = true
        loadError = nil
        do {
            let env = try await client.getDashboard(uid: uid)
            envelope = env
            recentStore.record(
                uid: env.dashboard.uid,
                title: env.dashboard.title,
                folderTitle: env.meta.folderTitle
            )
        } catch let err as GrafanaError {
            loadError = err
        } catch {
            AppLog.network.error("dashboard load failed: \(String(describing: error), privacy: .public)")
            loadError = .invalidResponse
        }
        isLoading = false
    }

    private func message(for err: GrafanaError) -> String {
        switch err {
        case .unauthorized: return "Your session expired."
        case .forbidden:    return "You don't have permission to see this dashboard."
        case .notFound:     return "Dashboard not found on the server."
        case .transport:    return "Network error. Check your connection."
        case .server, .invalidResponse, .decoding: return "The server returned an unexpected response."
        }
    }
}

private struct PanelPlaceholderCard: View {
    let panel: Panel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(panel.title ?? "(untitled panel)")
                    .font(.headline)
                Spacer()
                Text(panel.type)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: .capsule)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed").foregroundStyle(.secondary)
                Text("Panel rendering coming in Phase 2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 8))
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
    }
}
