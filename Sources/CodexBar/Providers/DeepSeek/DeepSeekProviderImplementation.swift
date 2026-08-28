import CodexBarCore
import Foundation
import SwiftUI

struct DeepSeekProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .deepseek

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_: SettingsStore) {}

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let presentationSnapshot = context.store.presentationSnapshot(for: .deepseek)
            ?? context.store.lastKnownResetSnapshots[.deepseek]
        let profiles = presentationSnapshot?.deepseekPlatformProfiles ?? []
        guard profiles.count > 1 || presentationSnapshot?.deepseekDetailedUsageState == .profileSelectionRequired
        else { return [] }
        let apiKey = context.settings.selectedTokenAccount(for: .deepseek)?.token
            ?? DeepSeekSettingsReader.apiKey(environment: context.store.environmentBase)
        let source = context.settings.providerConfig(for: .deepseek)?.source ?? .auto
        let selectedProfileID = context.settings.deepseekProfileID(apiKey: apiKey)
        let hasValidSelection = profiles.contains { $0.id == selectedProfileID }
        let profileBinding = Binding(
            get: {
                let profileID = context.settings.deepseekProfileID(apiKey: apiKey)
                return profiles.contains { $0.id == profileID } ? profileID : ""
            },
            set: { profileID in
                guard !profileID.isEmpty else { return }
                context.store.beginDeepSeekProfileTransition(preservingBalance: apiKey != nil && source != .web)
                context.settings.setDeepSeekProfileID(profileID, apiKey: apiKey)
            })
        let options = (hasValidSelection
            ? []
            : [ProviderSettingsPickerOption(id: "", title: "Select profile…")])
            + profiles.map { ProviderSettingsPickerOption(id: $0.id, title: $0.name) }

        return [
            ProviderSettingsPickerDescriptor(
                id: "deepseek-chrome-profile",
                title: "Chrome profile",
                subtitle: "Choose which signed-in DeepSeek Platform session supplies detailed usage.",
                dynamicSubtitle: {
                    context.store.refreshingProviders.contains(.deepseek)
                        ? "Refreshing"
                        : nil
                },
                binding: profileBinding,
                options: options,
                isVisible: nil,
                isEnabled: { !context.store.refreshingProviders.contains(.deepseek) },
                onChange: { _ in
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await context.store.refreshProvider(.deepseek, allowDisabled: true)
                    }
                }),
        ]
    }

    @MainActor
    func isAvailable(context _: ProviderAvailabilityContext) -> Bool {
        true
    }

    @MainActor
    func settingsFields(context _: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        []
    }
}
