import AppKit
import CodexBarCore

@MainActor
extension StatusItemController {
    func runFactoryLoginFlow() async {
        self.loginPhase = .waitingBrowser
        if let url = URL(string: "https://app.factory.ai") {
            NSWorkspace.shared.open(url)
        }
        // Give user time to complete login in browser
        try? await Task.sleep(for: .seconds(2))
        self.loginPhase = .idle
        self.postLoginNotification(for: .factory)
    }
}
