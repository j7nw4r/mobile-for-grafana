import Foundation

/// A Grafana folder. From `GET /api/folders`. Search filtering uses
/// `folderUIDs` (plural, UID-based) in Grafana 10+, not `folderIds`.
struct Folder: Sendable, Decodable, Hashable, Identifiable {
    let id: Int
    let uid: String
    let title: String
    let parentUid: String?
}

extension Folder {
    /// Grafana 11 returns a synthetic "Shared with me" folder with
    /// `id == -1`. It's not a real folder and shouldn't show up in
    /// the browse UI.
    var isSyntheticSharedWithMe: Bool {
        id < 0 || uid == "sharedwithme"
    }
}
