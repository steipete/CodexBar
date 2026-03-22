import CodexBarCore
import Foundation
import SwiftUI

/// Settings UI context passed to provider implementations.
///
/// Providers use this to:
/// - bind to `SettingsStore` values
/// - read current provider state from `UsageStore`
/// - surface transient status text (e.g. "Importing cookies…")
/// - request a shared confirmation alert (no provider-specific UI)
@MainActor
struct ProviderSettingsContext {
    let provider: UsageProvider
    let settings: SettingsStore
    let store: UsageStore

    let boolBinding: (ReferenceWritableKeyPath<SettingsStore, Bool>) -> Binding<Bool>
    let stringBinding: (ReferenceWritableKeyPath<SettingsStore, String>) -> Binding<String>

    let statusText: (String) -> String?
    let setStatusText: (String, String?) -> Void

    let lastAppActiveRunAt: (String) -> Date?
    let setLastAppActiveRunAt: (String, Date?) -> Void

    let requestConfirmation: (ProviderSettingsConfirmation) -> Void
}

/// Shared confirmation alert descriptor.
///
/// Providers can request confirmations (e.g. permission prompts) without supplying custom UI.
@MainActor
struct ProviderSettingsConfirmation {
    let title: String
    let message: String
    let confirmTitle: String
    let onConfirm: () -> Void
}

/// Shared toggle descriptor rendered in the Providers settings pane.
@MainActor
struct ProviderSettingsToggleDescriptor: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let binding: Binding<Bool>

    /// Optional short status text shown under the toggle when enabled.
    let statusText: (() -> String?)?

    /// Optional actions shown under the toggle when enabled.
    let actions: [ProviderSettingsActionDescriptor]

    /// Optional runtime visibility gate.
    let isVisible: (() -> Bool)?

    /// Called whenever the toggle changes.
    let onChange: ((_ enabled: Bool) async -> Void)?

    /// Called when the app becomes active (used for "retry after permission grant" flows).
    let onAppDidBecomeActive: (() async -> Void)?

    /// Called when the view appears while the toggle is enabled.
    let onAppearWhenEnabled: (() async -> Void)?
}

/// Shared text field descriptor rendered in the Providers settings pane.
@MainActor
struct ProviderSettingsFieldDescriptor: Identifiable {
    enum Kind {
        case plain
        case secure
    }

    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
    let placeholder: String?
    let binding: Binding<String>
    let actions: [ProviderSettingsActionDescriptor]
    let isVisible: (() -> Bool)?
    let onActivate: (() -> Void)?
}

/// Shared token account descriptor rendered in the Providers settings pane.
@MainActor
struct ProviderSettingsTokenAccountsDescriptor: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let placeholder: String
    /// When false, the token input is shown as plain text (e.g. file paths). Defaults to true.
    let isSecureToken: Bool
    let provider: UsageProvider
    let isVisible: (() -> Bool)?
    let accounts: () -> [ProviderTokenAccount]
    let activeIndex: () -> Int
    let setActiveIndex: (Int) -> Void
    let addAccount: (_ label: String, _ token: String) -> Void
    let removeAccount: (_ accountID: UUID) -> Void
    let moveAccount: (_ fromOffsets: IndexSet, _ toOffset: Int) -> Void
    let renameAccount: (_ accountID: UUID, _ newLabel: String) -> Void
    let openConfigFile: () -> Void
    let reloadFromDisk: () -> Void
    /// When set, the default (non-token-account) account label is shown as the first tab.
    /// Returns the display label (e.g. email) for the default account, or nil if unavailable.
    let defaultAccountLabel: (() -> String?)?
    /// When set, allows the user to set a custom display name for the default account.
    let renameDefaultAccount: ((_ newLabel: String) -> Void)?
    /// When set, shows a "Sign in to new account" button that calls this closure.
    /// The closure receives progress and addAccount callbacks; it adds the account itself and returns
    /// true on success or false on failure/cancellation.
    let loginAction: ((
        _ setProgress: @escaping @MainActor (String) -> Void,
        _ addAccount: @escaping @MainActor (String, String) -> Void) async -> Bool)?
    /// Opens a per-account dashboard login window (chatgpt.com) for web extras.
    /// The closure receives the account email (or nil for default).
    let dashboardLogin: ((_ accountEmail: String?) -> Void)?
    /// Codex only: mirrors **CodexBar accounts only**; hides ~/.codex primary tab and adjusts copy.
    let codexExplicitAccountsOnly: Bool
}

/// Which detail section a provider settings picker appears in.
enum ProviderSettingsPickerSection: Sendable {
    case settings
    case options
}

/// Shared picker descriptor rendered in the Providers settings pane.
@MainActor
struct ProviderSettingsPickerDescriptor: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let dynamicSubtitle: (() -> String?)?
    let binding: Binding<String>
    let options: [ProviderSettingsPickerOption]
    let isVisible: (() -> Bool)?
    let isEnabled: (() -> Bool)?
    let onChange: ((_ selection: String) async -> Void)?
    let trailingText: (() -> String?)?
    let section: ProviderSettingsPickerSection

    init(
        id: String,
        title: String,
        subtitle: String,
        dynamicSubtitle: (() -> String?)? = nil,
        binding: Binding<String>,
        options: [ProviderSettingsPickerOption],
        isVisible: (() -> Bool)?,
        isEnabled: (() -> Bool)? = nil,
        onChange: ((_ selection: String) async -> Void)?,
        trailingText: (() -> String?)? = nil,
        section: ProviderSettingsPickerSection = .settings)
    {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.dynamicSubtitle = dynamicSubtitle
        self.binding = binding
        self.options = options
        self.isVisible = isVisible
        self.isEnabled = isEnabled
        self.onChange = onChange
        self.trailingText = trailingText
        self.section = section
    }
}

struct ProviderSettingsPickerOption: Identifiable {
    let id: String
    let title: String
}

/// Shared action descriptor rendered under a settings toggle.
@MainActor
struct ProviderSettingsActionDescriptor: Identifiable {
    enum Style {
        case bordered
        case link
    }

    let id: String
    let title: String
    let style: Style
    let isVisible: (() -> Bool)?
    let perform: () async -> Void
}
