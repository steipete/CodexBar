import SwiftUI

@main
struct CodexBariOSApp: App {
    @State private var model = DashboardModel()

    var body: some Scene {
        WindowGroup {
            DashboardView(model: self.model)
        }
    }
}
