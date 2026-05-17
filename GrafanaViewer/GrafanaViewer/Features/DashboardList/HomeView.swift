import SwiftUI

struct HomeView: View {
    @Environment(ServerContext.self) private var session

    @State private var model = DashboardListModel()
    @State private var recentStore = RecentDashboardsStore()

    var body: some View {
        NavigationStack {
            List {
                starredSection
                recentSection
                foldersSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Dashboards")
            .refreshable { await loadAll() }
            .task { await loadAll() }
            .navigationDestination(for: Folder.self) { folder in
                FolderDetailView(folder: folder)
                    .environment(recentStore)
            }
            .navigationDestination(for: SearchHit.self) { hit in
                DashboardDetailView(uid: hit.uid, navTitle: hit.title)
                    .environment(recentStore)
            }
            .navigationDestination(for: RecentDashboardsStore.Entry.self) { entry in
                DashboardDetailView(uid: entry.uid, navTitle: entry.title)
                    .environment(recentStore)
            }
        }
        .environment(recentStore)
    }

    private func loadAll() async {
        guard let client = session.activeServer?.client else { return }
        await model.loadAll(client: client)
    }

    @ViewBuilder
    private var starredSection: some View {
        Section("Starred") {
            switch model.starred {
            case .idle, .loading:
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            case .failed(let err):
                SectionError(message: friendlyMessage(err)) {
                    Task { if let client = session.activeServer?.client { await model.loadStarred(client: client) } }
                }
            case .loaded(let hits):
                if hits.isEmpty {
                    Text("No starred dashboards.").foregroundStyle(.secondary)
                } else {
                    ForEach(hits) { hit in
                        NavigationLink(value: hit) { DashboardRow(hit: hit) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        Section("Recent") {
            if recentStore.entries.isEmpty {
                Text("Open a dashboard to see it here.").foregroundStyle(.secondary)
            } else {
                ForEach(recentStore.entries) { entry in
                    NavigationLink(value: entry) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                            if let folder = entry.folderTitle {
                                Text(folder).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var foldersSection: some View {
        Section("Folders") {
            switch model.folders {
            case .idle, .loading:
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            case .failed(let err):
                SectionError(message: friendlyMessage(err)) {
                    Task { if let client = session.activeServer?.client { await model.loadFolders(client: client) } }
                }
            case .loaded(let folders):
                if folders.isEmpty {
                    Text("No folders.").foregroundStyle(.secondary)
                } else {
                    ForEach(folders) { folder in
                        NavigationLink(value: folder) {
                            Label(folder.title, systemImage: "folder")
                        }
                    }
                }
            }
        }
    }

    private func friendlyMessage(_ err: GrafanaError) -> String {
        switch err {
        case .unauthorized: return "Your session expired."
        case .forbidden:    return "No permission."
        case .notFound:     return "Not found."
        case .transport:    return "Network error."
        case .server, .invalidResponse, .decoding: return "Server error."
        }
    }
}

struct DashboardRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.title)
            if let folder = hit.folderTitle {
                Text(folder).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SectionError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).foregroundStyle(.secondary)
            Spacer()
            Button("Retry", action: retry).buttonStyle(.bordered)
        }
    }
}
