import CodexBarCore
import Foundation
import Observation

extension SettingsPane {
    /// Stable token used to remember the selected pane across launches.
    var persistenceToken: String {
        switch self {
        case .general: "general"
        case .usageSpend: "usageSpend"
        case .notifications: "notifications"
        case .menuBar: "menuBar"
        case .menu: "menu"
        case .advanced: "advanced"
        case .hooks: "hooks"
        case .about: "about"
        case .debug: "debug"
        case let .provider(provider): "provider:\(provider.rawValue)"
        }
    }

    init?(persistenceToken: String) {
        switch persistenceToken {
        case "general": self = .general
        case "usageSpend": self = .usageSpend
        case "notifications": self = .notifications
        case "menuBar": self = .menuBar
        // Pre-0.41.1 releases persisted the retired Display pane; its contents moved to Menu Bar.
        case "display": self = .menuBar
        case "menu": self = .menu
        case "advanced": self = .advanced
        case "hooks": self = .hooks
        case "about": self = .about
        case "debug": self = .debug
        default:
            let providerPrefix = "provider:"
            guard persistenceToken.hasPrefix(providerPrefix),
                  let provider = UsageProvider(rawValue: String(persistenceToken.dropFirst(providerPrefix.count)))
            else {
                return nil
            }
            self = .provider(provider)
        }
    }
}

@MainActor
@Observable
final class PreferencesSelection {
    static let paneDefaultsKey = "settingsSelectedPane"

    private let userDefaults: UserDefaults

    var pane: SettingsPane {
        didSet {
            self.userDefaults.set(self.pane.persistenceToken, forKey: Self.paneDefaultsKey)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let token = userDefaults.string(forKey: Self.paneDefaultsKey) ?? ""
        self.pane = SettingsPane(persistenceToken: token) ?? .general
    }
}
