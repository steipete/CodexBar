import CodexBarCore

extension UsageStore {
    static func isGeminiConsumerTierDeprecationError(_ error: Error?) -> Bool {
        switch error as? GeminiStatusProbeError {
        case .consumerTierDeprecated, .oauthCredentialsUnavailableWithAntigravity:
            true
        default:
            false
        }
    }

    func observeGeminiConsumerTierDeprecation(from error: Error) {
        guard Self.isGeminiConsumerTierDeprecationError(error) else { return }
        self.geminiObservedConsumerTierDeprecation = true
    }

    func clearGeminiConsumerTierDeprecationObservation() {
        self.geminiObservedConsumerTierDeprecation = false
    }
}
