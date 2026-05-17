import SwiftUI
import OSLog

struct FolderDetailView: View {
    @Environment(ServerContext.self) private var session

    let folder: Folder

    @State private var allHits: [SearchHit] = []
    @State private var filter: String = ""
    @State private var loadError: GrafanaError?
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't load folder", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message(for: loadError))
                } actions: {
                    Button("Retry") { Task { await load() } }.buttonStyle(.borderedProminent)
                }
            } else if filteredHits.isEmpty {
                if allHits.isEmpty {
                    ContentUnavailableView("Empty folder", systemImage: "folder", description: Text("This folder has no dashboards."))
                } else {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass", description: Text("No dashboards in this folder match '\(filter)'."))
                }
            } else {
                ForEach(filteredHits) { hit in
                    NavigationLink(value: hit) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title)
                            if !hit.tags.isEmpty {
                                Text(hit.tags.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search this folder")
        .navigationTitle(folder.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var filteredHits: [SearchHit] {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return allHits }
        return allHits.filter { $0.title.lowercased().contains(trimmed) }
    }

    private func load() async {
        guard let client = session.activeServer?.client else { return }
        isLoading = true
        loadError = nil
        do {
            allHits = try await client.searchDashboards(folderUIDs: [folder.uid])
        } catch let err as GrafanaError {
            loadError = err
        } catch {
            AppLog.network.error("folder load failed: \(String(describing: error), privacy: .public)")
            loadError = .invalidResponse
        }
        isLoading = false
    }

    private func message(for err: GrafanaError) -> String {
        switch err {
        case .unauthorized: return "Your session expired."
        case .forbidden:    return "You don't have permission to see this folder."
        case .notFound:     return "Folder not found on the server."
        case .transport:    return "Network error. Check your connection."
        case .server, .invalidResponse, .decoding: return "The server returned an unexpected response."
        }
    }
}
