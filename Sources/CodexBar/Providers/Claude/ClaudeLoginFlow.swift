import CodexBarCore

@MainActor
extension StatusItemController {
    func runClaudeLoginFlow() async -> Bool {
        let phaseHandler: @Sendable (ClaudeLoginRunner.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in
                switch phase {
                case .requesting: self?.loginPhase = .requesting
                case .waitingBrowser: self?.loginPhase = .waitingBrowser
                }
            }
        }
        let result = await ClaudeLoginRunner.run(timeout: 120, onPhaseChange: phaseHandler)
        guard !Task.isCancelled else { return false }
        self.loginPhase = .idle
        self.presentClaudeLoginResult(result)
        let outcome = self.describe(result.outcome)
        let length = result.output.count
        self.loginLogger.info("Claude login", metadata: ["outcome": outcome, "length": "\(length)"])
        if case .success = result.outcome {
            let metadata = self.store.metadata(for: .claude)
            self.settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
            self.settings.claudeUsageDataSource = .oauth
            self.postLoginNotification(for: .claude)
            return true
        }
        return false
    }
}
