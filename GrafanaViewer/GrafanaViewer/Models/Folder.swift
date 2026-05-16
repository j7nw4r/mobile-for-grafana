import Foundation

/// A Grafana folder. Note: filtering uses `folderUIDs` (plural, UID-based) in
/// Grafana 10+, not `folderIds`.
struct Folder: Sendable, Hashable {
    let uid: String
    let title: String
}
