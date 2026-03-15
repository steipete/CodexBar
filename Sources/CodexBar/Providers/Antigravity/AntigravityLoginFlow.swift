import CodexBarCore

@MainActor
extension StatusItemController {
    func runAntigravityLoginFlow() async {
        self.loginPhase = .idle
        self.presentLoginAlert(
            title: String(localized: "Antigravity login is managed in the app"),
            message: String(localized: "Open Antigravity to sign in, then refresh CodexBar."))
    }
}
