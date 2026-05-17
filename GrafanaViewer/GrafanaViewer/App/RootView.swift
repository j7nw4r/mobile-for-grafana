import SwiftUI

struct RootView: View {
    @Environment(ServerContext.self) private var session

    var body: some View {
        if session.activeServer != nil {
            MainTabView()
        } else {
            LoginView()
        }
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Dashboards", systemImage: "rectangle.grid.2x2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
