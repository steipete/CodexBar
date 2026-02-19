import CodexBarCore

@MainActor
extension StatusItemController {
    func runAntigravityLoginFlow() async {
        self.loginPhase = .idle
        self.presentLoginAlert(
            title: L10n.tr("Antigravity login is managed in the app"),
            message: L10n.tr("Open Antigravity to sign in, then refresh CodexBar."))
    }
}
