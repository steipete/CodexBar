import CodexBarCore
import SwiftUI

struct WorkBuddyProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .workbuddy
    private let plugin = PluginCookieProviderImplementation(spec: WorkBuddyProviderDescriptor.spec)

    @MainActor
    func presentation(context: ProviderPresentationContext) -> ProviderPresentation {
        self.plugin.presentation(context: context)
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        self.plugin.observeSettings(settings)
        _ = settings.providerConfig(for: self.id)?.workBuddyUserAgent
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .workbuddy(.init(
            cookies: context.settings.resolvedCookieSettings(provider: self.id, tokenOverride: context.tokenOverride),
            manualUserAgent: context.settings.providerConfig(for: self.id)?.workBuddyUserAgent))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        self.plugin.settingsPickers(context: context)
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        self.plugin.settingsFields(context: context) + [ProviderSettingsFieldDescriptor(
            id: "workbuddy-user-agent",
            title: "User-Agent",
            subtitle: "Optional. Paste the User-Agent value from the same request as the Cookie.",
            kind: .plain,
            placeholder: nil,
            binding: Binding(
                get: { context.settings.providerConfig(for: self.id)?.workBuddyUserAgent ?? "" },
                set: { value in
                    context.settings.updateProviderConfig(provider: self.id) {
                        $0.workBuddyUserAgent = value.isEmpty ? nil : value
                    }
                }),
            actions: [],
            isVisible: { context.settings.resolvedCookieSource(provider: self.id, fallback: .auto) == .manual })]
    }
}
