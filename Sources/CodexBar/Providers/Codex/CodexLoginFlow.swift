import CodexBarCore

@MainActor
extension StatusItemController {
    func runCodexLoginFlow() async {
        // This menu action still follows the ambient Codex login behavior. Managed-account authentication is
        // implemented separately, but wiring add/switch/re-auth UI through that service needs its own account-aware
        // flow so this entry point does not silently change what "Switch Account" means for existing users.
        let result = await CodexLoginRunner.run(timeout: 120)
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
