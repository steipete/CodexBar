import CodexBarCore

@MainActor
extension StatusItemController {
    func runAntigravityLoginFlow() async {
        let store = self.store
        let phaseHandler: @Sendable (AntigravityLoginRunner.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in
                switch phase {
                case .waitingBrowser:
                    self?.loginPhase = .waitingBrowser
                }
            }
        }
        let result = await AntigravityLoginRunner.run(onPhaseChange: phaseHandler) {
            Task { @MainActor in
                await store.refresh()
                CodexBarLog.logger(LogCategories.login).info("Auto-refreshed after Antigravity auth")
            }
        }
        guard !Task.isCancelled else { return }
        self.loginPhase = .idle
        self.presentAntigravityLoginResult(result)
        let outcome = self.describe(result.outcome)
        self.loginLogger.info("Antigravity login", metadata: ["outcome": outcome])
        if case .success = result.outcome {
            self.postLoginNotification(for: .antigravity)
        }
    }
}
