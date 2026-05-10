import AppKit
import CodexBarCore
import Foundation
@preconcurrency import UserNotifications

enum SessionQuotaTransition: Equatable {
    case none
    case depleted
    case restored
}

struct QuotaWarningEvent: Equatable, Sendable {
    let window: QuotaWarningWindow
    let threshold: Int
    let currentRemaining: Double
}

enum SessionQuotaNotificationLogic {
    static let depletedThreshold: Double = 0.0001

    static func isDepleted(_ remaining: Double?) -> Bool {
        guard let remaining else { return false }
        return remaining <= Self.depletedThreshold
    }

    static func transition(previousRemaining: Double?, currentRemaining: Double?) -> SessionQuotaTransition {
        guard let currentRemaining else { return .none }
        guard let previousRemaining else { return .none }

        let wasDepleted = previousRemaining <= Self.depletedThreshold
        let isDepleted = currentRemaining <= Self.depletedThreshold

        if !wasDepleted, isDepleted { return .depleted }
        if wasDepleted, !isDepleted { return .restored }
        return .none
    }
}

enum QuotaWarningNotificationLogic {
    static func notificationCopy(
        providerName: String,
        window: QuotaWarningWindow,
        threshold: Int,
        currentRemaining: Double) -> (title: String, body: String)
    {
        let windowLabel = window.displayName
        let remainingText = Self.percentText(currentRemaining)
        return (
            "\(providerName) \(windowLabel) quota low",
            "\(remainingText) left. Reached your \(threshold)% \(windowLabel) warning threshold.")
    }

    static func crossedThreshold(
        previousRemaining: Double?,
        currentRemaining: Double,
        thresholds: [Int],
        alreadyFired: Set<Int>) -> Int?
    {
        let sanitized = QuotaWarningThresholds.active(thresholds)
        let eligible = sanitized.filter { threshold in
            currentRemaining <= Double(threshold) && !alreadyFired.contains(threshold)
        }
        guard !eligible.isEmpty else { return nil }

        if let previousRemaining {
            let crossed = eligible.filter { previousRemaining > Double($0) }
            return crossed.min()
        }

        return eligible.min()
    }

    static func firedThresholdsAfterWarning(threshold: Int, thresholds: [Int]) -> Set<Int> {
        Set(QuotaWarningThresholds.active(thresholds).filter { $0 >= threshold })
    }

    static func thresholdsToClear(currentRemaining: Double, alreadyFired: Set<Int>) -> Set<Int> {
        Set(alreadyFired.filter { currentRemaining > Double($0) })
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int(min(100, max(0, value)).rounded()))%"
    }
}

@MainActor
protocol SessionQuotaNotifying: AnyObject {
    func post(transition: SessionQuotaTransition, provider: UsageProvider, badge: NSNumber?)
    func postQuotaWarning(event: QuotaWarningEvent, provider: UsageProvider, soundEnabled: Bool)
}

@MainActor
final class SessionQuotaNotifier: SessionQuotaNotifying {
    private let logger = CodexBarLog.logger(LogCategories.sessionQuotaNotifications)

    init() {}

    func post(transition: SessionQuotaTransition, provider: UsageProvider, badge: NSNumber? = nil) {
        guard transition != .none else { return }

        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName

        let (title, body) = switch transition {
        case .none:
            ("", "")
        case .depleted:
            ("\(providerName) session depleted", "0% left. Will notify when it's available again.")
        case .restored:
            ("\(providerName) session restored", "Session quota is available again.")
        }

        let providerText = provider.rawValue
        let transitionText = String(describing: transition)
        let idPrefix = "session-\(providerText)-\(transitionText)"
        self.logger.info("enqueuing", metadata: ["prefix": idPrefix])
        AppNotifications.shared.post(idPrefix: idPrefix, title: title, body: body, badge: badge)
    }

    func postQuotaWarning(event: QuotaWarningEvent, provider: UsageProvider, soundEnabled: Bool = true) {
        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let threshold = event.threshold
        let copy = QuotaWarningNotificationLogic.notificationCopy(
            providerName: providerName,
            window: event.window,
            threshold: threshold,
            currentRemaining: event.currentRemaining)
        let idPrefix = "quota-warning-\(provider.rawValue)-\(event.window.rawValue)-\(threshold)"
        self.logger.info("enqueuing", metadata: ["prefix": idPrefix])
        if soundEnabled {
            (NSSound(named: "Glass") ?? NSSound(named: "Ping"))?.play()
        }
        NotificationCenter.default.post(
            name: .codexbarQuotaWarningDidPost,
            object: QuotaWarningPostedEvent(
                provider: provider,
                window: event.window,
                threshold: threshold,
                postedAt: Date()))
        AppNotifications.shared.post(idPrefix: idPrefix, title: copy.title, body: copy.body, soundEnabled: false)
    }
}
