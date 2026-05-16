import Foundation

/// A Grafana dashboard. Stub — full shape is defined in docs/03-api-and-models.md
/// and docs/06-dashboards-and-variables.md.
struct Dashboard: Sendable, Hashable {
    let uid: String
    let title: String
    let folderUID: String?
}
