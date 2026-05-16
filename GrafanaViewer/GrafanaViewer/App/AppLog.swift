import OSLog

/// OSLog subsystem + per-module categories. Use these instead of `print`.
enum AppLog {
    static let subsystem = "com.grafanaviewer.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let panels = Logger(subsystem: subsystem, category: "panels")
    static let datasources = Logger(subsystem: subsystem, category: "datasources")
}
