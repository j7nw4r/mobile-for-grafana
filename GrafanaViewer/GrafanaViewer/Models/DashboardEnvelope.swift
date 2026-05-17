import Foundation

/// `GET /api/dashboards/uid/{uid}` response.
struct DashboardEnvelope: Sendable, Decodable, Hashable {
    let dashboard: DashboardJSON
    let meta: DashboardMeta
}

struct DashboardMeta: Sendable, Decodable, Hashable {
    let isStarred: Bool
    let folderUid: String?
    let folderTitle: String?
    let url: String?
    let updated: String?
    let version: Int?
}

/// Dashboard JSON. Per docs/03 we deliberately model only the subset we
/// need to render; unknown fields are ignored at decode time. Phase 1
/// needs `uid`, `title`, and the panel shells (`id`, `type`, `title`).
/// Phase 3/4 grow this with templating, time, annotations.
struct DashboardJSON: Sendable, Decodable, Hashable {
    let uid: String
    let title: String
    let tags: [String]?
    let panels: [Panel]
}

/// Phase 1 minimum: just enough to show a panel placeholder. Phase 2
/// adds `targets`, `gridPos`, `fieldConfig`, and the per-type options
/// needed to render.
struct Panel: Sendable, Decodable, Hashable, Identifiable {
    let id: Int
    let type: String
    let title: String?
}
