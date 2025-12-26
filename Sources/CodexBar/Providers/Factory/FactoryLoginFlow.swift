import AppKit
import CodexBarCore

@MainActor
extension StatusItemController {
    func runFactoryLoginFlow() async -> Bool {
        self.loginPhase = .waitingBrowser
        if let url = URL(string: "https://app.factory.ai") {
            NSWorkspace.shared.open(url)
        }

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if Task.isCancelled {
                self.loginPhase = .idle
                return false
            }

            if await FactoryTokenImporter.hasSession() {
                self.loginPhase = .idle
                self.postLoginNotification(for: .factory)
                return true
            }

            try? await Task.sleep(for: .seconds(2))
        }

        self.loginPhase = .idle
        self.presentLoginAlert(
            title: "Factory login not detected",
            message: "Sign in to app.factory.ai in Chrome, then try again.")
        return false
    }
}
