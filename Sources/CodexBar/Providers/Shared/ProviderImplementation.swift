import CodexBarCore
import Foundation

/// App-side provider implementation.
///
/// Rules:
/// - Provider implementations return *data/behavior descriptors*; the app owns UI.
/// - Do not mix identity fields across providers (email/org/plan/loginMethod stays siloed).
protocol ProviderImplementation: Sendable {
    var id: UsageProvider { get }
    var supportsLoginFlow: Bool { get }

    @MainActor
    func presentation(context: ProviderPresentationContext) -> ProviderPresentation

    @MainActor
    func observeSettings(_ settings: SettingsStore)

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String?

    @MainActor
    func decorateSourceLabel(context: ProviderSourceLabelContext, baseLabel: String) -> String

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode

    func detectVersion(context: ProviderVersionContext) async -> String?

    func makeRuntime() -> (any ProviderRuntime)?

    /// Optional provider-specific settings toggles to render in the Providers pane.
    ///
    /// Important: Providers must not return custom SwiftUI views here. Only shared toggle/action descriptors.
    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor]

    /// Optional provider-specific settings fields to render in the Providers pane.
    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor]

    /// Optional provider-specific settings pickers to render in the Providers pane.
    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor]

    /// Optional visibility gate for token account settings.
    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool

    /// Optional provider-specific settings snapshot contribution.
    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution?

    /// Optional hook to update provider settings when token accounts change.
    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore)

    /// Optional provider-specific menu entries for the usage section.
    @MainActor
    func appendUsageMenuEntries(context: ProviderMenuUsageContext, entries: inout [ProviderMenuEntry])

    /// Optional provider-specific menu entries for the actions section.
    @MainActor
    func appendActionMenuEntries(context: ProviderMenuActionContext, entries: inout [ProviderMenuEntry])

    /// Optional override for the login/switch account menu action.
    @MainActor
    func loginMenuAction(context: ProviderMenuLoginContext) -> (label: String, action: MenuDescriptor.MenuAction)?

    /// Optional provider-specific login flow. Returns whether to refresh after completion.
    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool
}

extension ProviderImplementation {
    var supportsLoginFlow: Bool {
        false
    }

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation(detailLine: ProviderPresentation.standardDetailLine)
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings
    }

    @MainActor
    func isAvailable(context _: ProviderAvailabilityContext) -> Bool {
        true
    }

    @MainActor
    func defaultSourceLabel(context _: ProviderSourceLabelContext) -> String? {
        nil
    }

    @MainActor
    func decorateSourceLabel(context _: ProviderSourceLabelContext, baseLabel: String) -> String {
        baseLabel
    }

    @MainActor
    func sourceMode(context _: ProviderSourceModeContext) -> ProviderSourceMode {
        .auto
    }

    func detectVersion(context: ProviderVersionContext) async -> String? {
        let detector = ProviderDescriptorRegistry.descriptor(for: self.id).cli.versionDetector
        return detector?(context.browserDetection)
    }

    func makeRuntime() -> (any ProviderRuntime)? {
        nil
    }

    @MainActor
    func settingsToggles(context _: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        []
    }

    @MainActor
    func settingsFields(context _: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        []
    }

    @MainActor
    func settingsPickers(context _: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        []
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        return !context.settings.tokenAccounts(for: context.provider).isEmpty
    }

    @MainActor
    func settingsSnapshot(context _: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        nil
    }

    @MainActor
    func applyTokenAccountCookieSource(settings _: SettingsStore) {}

    @MainActor
    func appendUsageMenuEntries(context _: ProviderMenuUsageContext, entries _: inout [ProviderMenuEntry]) {}

    @MainActor
    func appendActionMenuEntries(context _: ProviderMenuActionContext, entries _: inout [ProviderMenuEntry]) {}

    @MainActor
    func loginMenuAction(context _: ProviderMenuLoginContext)
        -> (label: String, action: MenuDescriptor.MenuAction)?
    {
        nil
    }

    @MainActor
    func runLoginFlow(context _: ProviderLoginContext) async -> Bool {
        false
    }
}

struct ProviderLoginContext {
    unowned let controller: StatusItemController
}
