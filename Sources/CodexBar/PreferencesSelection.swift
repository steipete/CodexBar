import CodexBarCore
import Foundation
import Observation

extension SettingsPane {
    /// Stable token used to remember the selected pane across launches.
    var persistenceToken: String {
        switch self {
        case .general: "general"
        case .iCloudSync: "iCloudSync"
        case .usageSpend: "usageSpend"
        case .notifications: "notifications"
        case .menuBar: "menuBar"
        case .menu: "menu"
        case .notch: "notch"
        case .advanced: "advanced"
        case .hooks: "hooks"
        case .plugins: "plugins"
        case .about: "about"
        case .debug: "debug"
        case let .provider(provider): "provider:\(provider.rawValue)"
        }
    }

    init?(persistenceToken: String) {
        switch persistenceToken {
        case "general": self = .general
        case "iCloudSync": self = .iCloudSync
        case "usageSpend": self = .usageSpend
        case "notifications": self = .notifications
        case "menuBar": self = .menuBar
        // Pre-0.41.1 releases persisted the retired Display pane; its contents moved to Menu Bar.
        case "display": self = .menuBar
        case "menu": self = .menu
        case "notch": self = .notch
        case "advanced": self = .advanced
        case "hooks": self = .hooks
        case "plugins": self = .plugins
        case "about": self = .about
        case "debug": self = .debug
        default:
            let providerPrefix = "provider:"
            guard persistenceToken.hasPrefix(providerPrefix),
                  let instanceID = ProviderInstanceID(
                      rawValue: String(persistenceToken.dropFirst(providerPrefix.count))),
                  instanceID.firstPartyProvider != nil || UserProviderPluginRegistry.plugin(for: instanceID) != nil
            else {
                return nil
            }
            self = .provider(instanceID)
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
