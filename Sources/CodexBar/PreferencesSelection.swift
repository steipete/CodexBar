import CodexBarCore
import Foundation
import Observation

extension SettingsPane {
    /// Stable token used to remember the selected pane across launches.
    var persistenceToken: String {
        switch self {
        case .general: "general"
        case .display: "display"
        case .advanced: "advanced"
        case .about: "about"
        case .debug: "debug"
        case let .provider(provider): "provider:\(provider.rawValue)"
        }
    }

    init?(persistenceToken: String) {
        switch persistenceToken {
        case "general": self = .general
        case "display": self = .display
        case "advanced": self = .advanced
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
