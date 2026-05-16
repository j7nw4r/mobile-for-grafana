import SwiftUI

struct RootView: View {
    @Environment(ServerContext.self) private var session

    var body: some View {
        if session.activeServer != nil {
            SignedInView()
        } else {
            LoginView()
        }
    }
}
