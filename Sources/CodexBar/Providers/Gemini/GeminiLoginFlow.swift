import CodexBarCore

@MainActor
extension StatusItemController {
    func runGeminiLoginFlow() async {
        let store = self.store
        let result = await GeminiLoginRunner.run {
            Task { @MainActor in
                await store.refresh()
                CodexBarLog.logger(LogCategories.login).info("Auto-refreshed after Gemini auth")
            }
        }
        guard !Task.isCancelled else { return }
        self.loginPhase = .idle
        self.presentGeminiLoginResult(result)
        let outcome = self.describe(result.outcome)
        self.loginLogger.info("Gemini login", metadata: ["outcome": outcome])
    }
}
