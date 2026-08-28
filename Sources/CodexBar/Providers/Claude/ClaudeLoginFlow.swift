import CodexBarCore
import Foundation

typealias ClaudeLoginFlowRunner = (
    _ timeout: TimeInterval,
    _ onPhaseChange: @escaping @Sendable (ClaudeLoginRunner.Phase) -> Void) async -> ClaudeLoginRunner.Result

@MainActor
extension StatusItemController {
    func runClaudeLoginFlow() async -> Bool {
        await self.runClaudeLoginFlow(
            loginRunner: { timeout, onPhaseChange in
                await ClaudeLoginRunner.run(timeout: timeout, onPhaseChange: onPhaseChange)
            })
    }

    func runClaudeLoginFlow(loginRunner: ClaudeLoginFlowRunner) async -> Bool {
        let phaseHandler: @Sendable (ClaudeLoginRunner.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in
                switch phase {
                case .requesting: self?.loginPhase = .requesting
                case .waitingBrowser: self?.loginPhase = .waitingBrowser
                }
            }
        }
        let result = await loginRunner(120, phaseHandler)
        guard !Task.isCancelled else { return false }
        self.loginPhase = .idle
        self.presentClaudeLoginResult(result)
        let outcome = self.describe(result.outcome)
        let length = result.output.count
        self.loginLogger.info("Claude login", metadata: ["outcome": outcome, "length": "\(length)"])
        if case .success = result.outcome {
            let metadata = self.store.metadata(for: .claude)
            self.settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
            self.postLoginNotification(for: .claude)
            return true
        }
        return false
    }
}
