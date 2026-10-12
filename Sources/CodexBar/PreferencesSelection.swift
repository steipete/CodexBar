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
            guard !self.isTraversingHistory, oldValue != self.pane else { return }
            self.backStack.append(oldValue)
            self.forwardStack.removeAll()
        }
    }

    private(set) var backStack: [SettingsPane] = []
    private(set) var forwardStack: [SettingsPane] = []
    @ObservationIgnored private var isTraversingHistory = false

    var canGoBack: Bool {
        !self.backStack.isEmpty
    }

    var canGoForward: Bool {
        !self.forwardStack.isEmpty
    }

    func goBack() {
        guard let previous = self.backStack.popLast() else { return }
        self.forwardStack.append(self.pane)
        self.traverseHistory(to: previous)
    }

    func goForward() {
        guard let next = self.forwardStack.popLast() else { return }
        self.backStack.append(self.pane)
        self.traverseHistory(to: next)
    }

    private func traverseHistory(to pane: SettingsPane) {
        self.isTraversingHistory = true
        defer { self.isTraversingHistory = false }
        self.pane = pane
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let token = userDefaults.string(forKey: Self.paneDefaultsKey) ?? ""
        self.pane = SettingsPane(persistenceToken: token) ?? .general
    }
}
