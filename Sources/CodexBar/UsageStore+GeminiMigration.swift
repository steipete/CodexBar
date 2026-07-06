import CodexBarCore
import Foundation

@MainActor
enum GeminiConsumerTierDeprecationObservation {
    private static var observedByStore: [ObjectIdentifier: Bool] = [:]

    static func observed(for store: UsageStore) -> Bool {
        self.observedByStore[ObjectIdentifier(store)] ?? false
    }

    static func setObserved(_ observed: Bool, for store: UsageStore) {
        self.observedByStore[ObjectIdentifier(store)] = observed
    }
}

extension UsageStore {
    var geminiObservedConsumerTierDeprecation: Bool {
        GeminiConsumerTierDeprecationObservation.observed(for: self)
    }

    static func isGeminiConsumerTierDeprecationError(_ error: Error?) -> Bool {
        (error as? GeminiStatusProbeError) == .consumerTierDeprecated
    }

    func syncGeminiConsumerTierDeprecationObservation(from error: Error?) {
        GeminiConsumerTierDeprecationObservation.setObserved(
            Self.isGeminiConsumerTierDeprecationError(error),
            for: self)
    }
}
