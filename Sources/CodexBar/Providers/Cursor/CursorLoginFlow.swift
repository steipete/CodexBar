import CodexBarCore

@MainActor
extension StatusItemController {
    func runCursorLoginFlow() async {
        let cursorRunner = CursorLoginRunner(browserDetection: self.store.browserDetection)
        let phaseHandler: @Sendable (CursorLoginRunner.Phase) -> Void = { [weak self] phase in
            Task { @MainActor in
                switch phase {
                case .loading, .waitingLogin:
                    self?.loginPhase = .waitingBrowser
                case .success, .failed:
                    self?.loginPhase = .idle
                }
            }
        }
        let result = await cursorRunner.run(onPhaseChange: phaseHandler)
        guard !Task.isCancelled else { return }
        self.loginPhase = .idle
        self.presentCursorLoginResult(result)
        let outcome = self.describe(result.outcome)
        self.loginLogger.info("Cursor login", metadata: ["outcome": outcome])
        if case .success = result.outcome {
            self.postLoginNotification(for: .cursor)
        }
    }
}
