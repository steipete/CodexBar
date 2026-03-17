import CodexBarCore

@MainActor
extension StatusItemController {
    func runAntigravityLoginFlow() async {
        self.loginPhase = .idle
        self.presentLoginAlert(
            title: AppStrings.tr("Antigravity login is managed in the app"),
            message: AppStrings.tr("Open Antigravity to sign in, then refresh CodexBar."))
    }
}
