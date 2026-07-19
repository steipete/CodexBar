import CodexBarCore

extension UsageStore {
    static func isGeminiConsumerTierDeprecationError(_ error: Error?) -> Bool {
        (error as? GeminiStatusProbeError) == .consumerTierDeprecated
    }

    func observeGeminiConsumerTierDeprecation(from error: Error) {
        guard Self.isGeminiConsumerTierDeprecationError(error) else { return }
        self.geminiObservedConsumerTierDeprecation = true
    }

    func clearGeminiConsumerTierDeprecationObservation() {
        self.geminiObservedConsumerTierDeprecation = false
    }
}
