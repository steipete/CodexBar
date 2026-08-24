import CodexBarCore

@MainActor
extension StatusItemController {
    func runGeminiLoginFlow() async {
        let store = self.store
        let onCredentialsCreated: @Sendable () -> Void = {
            Task { @MainActor in
                await store.refresh()
                CodexBarLog.logger(LogCategories.login).info("Auto-refreshed after Gemini auth")
            }
        }

        var result = await GeminiLoginRunner.run(
            consumerTierDeprecationObserved: store.geminiObservedGoogleConsumerTierShutdown,
            onCredentialsCreated: onCredentialsCreated)
        guard !Task.isCancelled else { return }
        self.loginPhase = .idle

        if self.presentGeminiLoginResult(result) {
            // The alert warned that continuing clears the stored credentials; the user asked to switch to
            // an account Google still serves, so run the ordinary flow without the shutdown guard.
            self.loginLogger.info("Gemini login", metadata: ["outcome": "consumerTierDeprecatedOverride"])
            result = await GeminiLoginRunner.run(onCredentialsCreated: onCredentialsCreated)
            guard !Task.isCancelled else { return }
            self.presentGeminiLoginResult(result)
        }

        let outcome = self.describe(result.outcome)
        self.loginLogger.info("Gemini login", metadata: ["outcome": outcome])
    }
}
