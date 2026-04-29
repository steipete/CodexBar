import CodexBarCore
import Foundation

enum SessionQuotaTransition: Equatable {
    case none
    case depleted
    case restored
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

@MainActor
protocol SessionQuotaNotifying: AnyObject {
    func post(transition: SessionQuotaTransition, provider: UsageProvider, badge: NSNumber?)
}

@MainActor
final class SessionQuotaNotifier: SessionQuotaNotifying {
    private let logger = CodexBarLog.logger(LogCategories.sessionQuotaNotifications)
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func post(transition: SessionQuotaTransition, provider: UsageProvider, badge: NSNumber? = nil) {
        guard transition != .none else { return }

        let providerName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let event: AppNotificationEvent
        let title: String
        let body: String
        switch transition {
        case .none:
            event = .sessionQuotaDepleted
            title = ""
            body = ""
        case .depleted:
            event = .sessionQuotaDepleted
            title = "\(providerName) session depleted"
            body = "0% left. Will notify when it's available again."
        case .restored:
            event = .sessionQuotaRestored
            title = "\(providerName) session restored"
            body = "Session quota is available again."
        }

        let providerText = provider.rawValue
        let transitionText = String(describing: transition)
        let idPrefix = "session-\(providerText)-\(transitionText)"
        self.logger.info("enqueuing", metadata: ["prefix": idPrefix])
        AppNotifications.shared.post(
            idPrefix: idPrefix,
            title: title,
            body: body,
            badge: badge,
            event: event,
            provider: providerName,
            notificationsEnabled: self.settings.notificationsEnabled,
            notificationVolume: self.settings.notificationVolume,
            settings: self.settings.notificationSettings(for: event))
    }
}
