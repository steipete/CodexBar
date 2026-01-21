import CodexBarCore

@MainActor
extension StatusItemController {
    func runCodexLoginFlow() async {
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
