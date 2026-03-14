import CodexBarCore
import Foundation

enum QuotaWarningWindow: String, Sendable {
    case primary
    case secondary
}

struct QuotaWarningEvent: Equatable, Sendable {
    let threshold: Int
    let window: QuotaWarningWindow
    let currentRemaining: Double
}

enum QuotaWarningNotificationLogic {
    /// Returns thresholds that were newly crossed downward.
    /// A threshold is considered crossed when `previousRemaining > threshold` and
    /// `currentRemaining <= threshold`, and the threshold has not already fired.
    static func crossedThresholds(
        previousRemaining: Double?,
        currentRemaining: Double,
        thresholds: [Int],
        alreadyFired: Set<Int>
    ) -> [Int] {
        guard let previousRemaining else { return [] }

        var crossed: [Int] = []
        for threshold in thresholds {
            let t = Double(threshold)
            if previousRemaining > t,
               currentRemaining <= t,
               !alreadyFired.contains(threshold)
            {
                crossed.append(threshold)
            }
        }
        return crossed
    }

    /// Returns thresholds that should be cleared from `alreadyFired` because
    /// the remaining percentage has risen back above them.
    static func restoredThresholds(
        currentRemaining: Double,
        alreadyFired: Set<Int>
    ) -> Set<Int> {
        Set(alreadyFired.filter { Double($0) < currentRemaining })
    }
}

@MainActor
final class QuotaWarningNotifier {
    private let logger = CodexBarLog.logger(LogCategories.quotaWarningNotifications)

    init() {}

    func post(event: QuotaWarningEvent, provider: UsageProvider) {
        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let windowLabel = event.window == .primary ? "session" : "weekly"

        let title = "\(providerName) \(windowLabel) quota low"
        let body = "\(event.threshold)% remaining – currently at \(Int(event.currentRemaining))%."

        let idPrefix = "quota-warning-\(provider.rawValue)-\(event.window.rawValue)-\(event.threshold)"
        self.logger.info("enqueuing", metadata: ["prefix": idPrefix])
        AppNotifications.shared.post(idPrefix: idPrefix, title: title, body: body)
    }
}
