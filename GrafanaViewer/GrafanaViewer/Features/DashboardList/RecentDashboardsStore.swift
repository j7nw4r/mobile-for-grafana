import Foundation
import Observation

/// Tracks the dashboards the user has recently opened, persisted in
/// `UserDefaults`. Capped at 20 entries (per docs/01). Scoped to the
/// `DashboardList` feature — injected via `.environment` at `HomeView`.
@MainActor
@Observable
final class RecentDashboardsStore {
    private(set) var entries: [Entry]

    private let defaults: UserDefaults
    private let key: String
    private let cap: Int

    struct Entry: Sendable, Codable, Hashable, Identifiable {
        let uid: String
        let title: String
        let folderTitle: String?

        var id: String { uid }
    }

    init(defaults: UserDefaults = .standard, key: String = "recentDashboards", cap: Int = 20) {
        self.defaults = defaults
        self.key = key
        self.cap = cap
        self.entries = Self.load(defaults: defaults, key: key)
    }

    /// Record a dashboard as just-opened. Idempotent: if the uid is
    /// already in the list it moves to the front rather than duplicating.
    func record(uid: String, title: String, folderTitle: String?) {
        var next = entries.filter { $0.uid != uid }
        next.insert(Entry(uid: uid, title: title, folderTitle: folderTitle), at: 0)
        if next.count > cap { next.removeLast(next.count - cap) }
        entries = next
        persist()
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(defaults: UserDefaults, key: String) -> [Entry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }
}
