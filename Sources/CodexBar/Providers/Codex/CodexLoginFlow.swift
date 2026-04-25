import CodexBarCore

@MainActor
extension StatusItemController {
    func runCodexLoginFlow() async {
        // This menu action still follows the ambient Codex login behavior. Managed-account authentication is
        // implemented separately, but wiring add/switch/re-auth UI through that service needs its own account-aware
        // flow so this entry point does not silently change what "Switch Account" means for existing users.
        self.codexAccountPromotionCoordinator.setLiveReauthenticationInProgress(true)
        defer {
            self.codexAccountPromotionCoordinator.setLiveReauthenticationInProgress(false)
        }
        #if DEBUG
        let result =
            if let override = self._test_codexAmbientLoginRunnerOverride {
                await override(120)
            } else {
                await CodexLoginRunner.run(timeout: 120)
            }
        #else
        let result = await CodexLoginRunner.run(timeout: 120)
        #endif
        guard !Task.isCancelled else { return }
        self.loginPhase = .idle
        self.presentCodexLoginResult(result)
        let outcome = self.describe(result.outcome)
        let length = result.output.count
        self.loginLogger.info("Codex login", metadata: ["outcome": outcome, "length": "\(length)"])
        if case .success = result.outcome {
            self.postLoginNotification(for: .codex)
        }
    }
}
