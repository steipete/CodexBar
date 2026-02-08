import SwiftUI

@main
struct CodexBariOSApp: App {
    @State private var viewModel = UsageDashboardViewModel()

    var body: some Scene {
        WindowGroup {
            UsageDashboardView(viewModel: self.viewModel)
        }
    }
}
