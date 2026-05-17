import Foundation
import Observation
import OSLog

/// Feature-local state for `HomeView`. Each section (starred / folders)
/// loads independently and can fail independently so a single broken
/// permission (e.g. folder access denied for a Viewer token) doesn't
/// blank the whole screen.
///
/// Recents are owned by `RecentDashboardsStore` and read directly by the
/// view; not duplicated here.
@MainActor
@Observable
final class DashboardListModel {
    enum SectionState<Value: Sendable>: Sendable {
        case idle
        case loading
        case loaded(Value)
        case failed(GrafanaError)
    }

    var starred: SectionState<[SearchHit]> = .idle
    var folders: SectionState<[Folder]> = .idle

    func loadAll(client: GrafanaClient) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in await self.loadStarred(client: client) }
            group.addTask { @MainActor in await self.loadFolders(client: client) }
        }
    }

    func loadStarred(client: GrafanaClient) async {
        starred = .loading
        do {
            let hits = try await client.searchDashboards(starred: true)
            starred = .loaded(hits)
        } catch let err as GrafanaError {
            AppLog.network.error("starred load failed: \(String(describing: err), privacy: .public)")
            starred = .failed(err)
        } catch {
            AppLog.network.error("starred load failed: \(String(describing: error), privacy: .public)")
            starred = .failed(.invalidResponse)
        }
    }

    func loadFolders(client: GrafanaClient) async {
        folders = .loading
        do {
            let all = try await client.listFolders()
            // Hide the synthetic "Shared with me" Grafana 11 returns by default.
            folders = .loaded(all.filter { !$0.isSyntheticSharedWithMe })
        } catch let err as GrafanaError {
            AppLog.network.error("folders load failed: \(String(describing: err), privacy: .public)")
            folders = .failed(err)
        } catch {
            AppLog.network.error("folders load failed: \(String(describing: error), privacy: .public)")
            folders = .failed(.invalidResponse)
        }
    }
}
