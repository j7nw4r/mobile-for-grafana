import Foundation

/// One row of `GET /api/search`. `type` discriminates folder rows from
/// dashboard rows; we always pass `type=dash-db` when querying the
/// dashboards browse UI, but accept either at decode time so callers
/// don't have to remember to filter.
struct SearchHit: Sendable, Decodable, Hashable, Identifiable {
    enum Kind: String, Sendable, Decodable, Hashable {
        case dashboard = "dash-db"
        case folder = "dash-folder"
    }

    let id: Int
    let uid: String
    let title: String
    let type: Kind
    let url: String
    let folderUid: String?
    let folderTitle: String?
    let tags: [String]
    let isStarred: Bool?
    let sortMeta: Int?
}
