import AppKit
import CodexBarCore

extension StatusItemController {
    enum StatusItemIdentity {
        case merged
        case provider(ProviderInstanceID)
        case account(AccountStatusItemKey)

        var autosaveName: String {
            switch self {
            case .merged:
                "codexbar-merged"
            case let .provider(provider):
                "codexbar-\(provider.rawValue)"
            case let .account(key):
                "codexbar-\(key.provider.rawValue)-account-\(key.accountID)"
            }
        }

        var accessibilityIdentifier: String {
            switch self {
            case .merged:
                return StatusItemController.statusItemAccessibilityIdentifierPrefix
            case let .provider(provider):
                return "\(StatusItemController.statusItemAccessibilityIdentifierPrefix).\(provider.rawValue)"
            case let .account(key):
                let prefix = StatusItemController.statusItemAccessibilityIdentifierPrefix
                return "\(prefix).\(key.provider.rawValue).account.\(key.accountID)"
            }
        }
    }

    nonisolated static func isDebugApp(bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.contains(".debug") == true
    }

    nonisolated static func statusItemAccessibilityTitle(isDebugApp: Bool) -> String {
        isDebugApp ? self.debugStatusItemAccessibilityTitle : self.statusItemAccessibilityTitle
    }

    // swiftlint:disable:next function_parameter_count
    static func makeDefaultController(
        store: UsageStore,
        settings: SettingsStore,
        account: AccountInfo,
        updater: UpdaterProviding,
        selection: PreferencesSelection,
        managedCodexAccountCoordinator: ManagedCodexAccountCoordinator,
        codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator)
        -> StatusItemControlling
    {
        StatusItemController(
            store: store,
            settings: settings,
            account: account,
            updater: updater,
            preferencesSelection: selection,
            managedCodexAccountCoordinator: managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: codexAccountPromotionCoordinator)
    }

    static func makeStatusItem(
        statusBar: NSStatusBar,
        identity: StatusItemIdentity,
        defaults: UserDefaults,
        legacyDefaultItemIndex: Int?,
        displayName: String? = nil,
        onCreated: ((NSStatusItem) -> Void)? = nil)
        -> NSStatusItem
    {
        MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: identity.autosaveName,
            legacyDefaultItemIndex: legacyDefaultItemIndex)
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        onCreated?(item)
        item.autosaveName = identity.autosaveName
        if let button = item.button {
            let baseTitle = self.statusItemAccessibilityTitle(
                isDebugApp: self.isDebugApp(bundleIdentifier: Bundle.main.bundleIdentifier))
            let title = displayName.map { "\(baseTitle) — \($0)" } ?? baseTitle
            // Ensure the icon is rendered at 1:1 without resampling (crisper edges for template images).
            button.imageScaling = .scaleNone
            button.setAccessibilityIdentifier(identity.accessibilityIdentifier)
            button.setAccessibilityTitle(title)
        }
        return item
    }
}
