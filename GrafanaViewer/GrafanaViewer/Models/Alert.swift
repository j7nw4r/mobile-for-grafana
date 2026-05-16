import Foundation

/// A Grafana alert instance. Note: two listing endpoints exist —
/// `/api/prometheus/grafana/api/v1/alerts` (rule engine state) and
/// `/api/alertmanager/grafana/api/v2/alerts` (notification pipeline). They are
/// not interchangeable; see docs/07-alerts.md.
struct Alert: Sendable, Hashable {
    let name: String
    let state: String
}
