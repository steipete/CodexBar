import CodexBarCore
import Foundation

/// Result of asking a provider to make one of its accounts the System account.
enum SystemAccountSwitchOutcome: Equatable {
    case succeeded
    case failed(title: String, message: String)
    /// The provider's configuration changed while switching; the result no longer applies.
    case discarded
}

struct SystemAccountMenuEntry: Equatable {
    let accountID: String
    /// Already redacted for Hide Personal Info.
    let title: String
    let isSystem: Bool
    let isSwitchable: Bool
}

struct SystemAccountMenuEntries: Equatable {
    /// Product name of the CLI whose login changes, for feedback copy.
    let cliName: String
    let isBlocked: Bool
    let entries: [SystemAccountMenuEntry]
}

@MainActor
struct SystemAccountSwitchContext {
    let store: UsageStore
    let settings: SettingsStore
    let codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator?
}

/// Builds the shared "System Account" submenu. Providers decide which accounts exist and which can be switched to;
/// the submenu shape, checkmark, enablement and action are the same for every provider.
enum SystemAccountMenu {
    static func append(
        _ menu: SystemAccountMenuEntries,
        provider: UsageProvider,
        to entries: inout [ProviderMenuEntry])
    {
        let items = menu.entries.map { entry in
            let canSwitch = entry.isSwitchable && !entry.isSystem
            return MenuDescriptor.SubmenuItem(
                title: entry.title,
                action: canSwitch ? .requestSystemAccountSwitch(provider: provider, accountID: entry.accountID) : nil,
                isEnabled: canSwitch && !menu.isBlocked,
                isChecked: entry.isSystem)
        }
        guard items.count > 1 || items.contains(where: { $0.isEnabled && $0.action != nil }) else { return }
        entries.append(.submenu(
            L("System Account"),
            MenuDescriptor.MenuActionSystemImage.systemAccount.rawValue,
            items))
    }
}
