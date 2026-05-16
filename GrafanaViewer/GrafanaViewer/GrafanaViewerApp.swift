import SwiftUI

@main
struct GrafanaViewerApp: App {
    @State private var session: ServerContext

    init() {
        let context = ServerContext()
        context.restore()
        _session = State(initialValue: context)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}
