import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct OpenRouterProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .openrouter

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .openrouter, field: .apiKey]
        _ = settings[providerConfig: .openrouter, field: .endpoint]
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        ProviderDescriptorRegistry.descriptor(for: self.id).settingsSection.credentialContribution(
            context: ProviderCredentialSettingsContext(
                config: context.settings.providerConfig(for: self.id),
                account: nil))
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if OpenRouterSettingsReader.apiToken(environment: context.environment) != nil {
            return true
        }
        return !context.settings[providerConfig: .openrouter, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    func settingsPickers(context _: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        []
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "openrouter-api-key",
                title: "Inference or management API key",
                subtitle: "Stored in ~/.codexbar/config.json. "
                    + "Inference keys provide credits and key quota. On the official OpenRouter API, "
                    + "management keys also add 30-day tokens, models, requests, and spend.",
                kind: .secure,
                placeholder: "sk-or-v1-...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "openrouter-api-url",
                title: "API URL",
                subtitle: "Optional. Defaults to the hosted OpenRouter API.",
                kind: .plain,
                placeholder: "https://openrouter.ai/api/v1",
                binding: context.providerConfigBinding(.endpoint),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "openrouter-management-api-key",
                title: "Management API key",
                subtitle: "Optional separate credential. Adds exact tokens, models, requests, and spend for the "
                    + "last 30 completed UTC days to Usage & Spend.",
                kind: .secure,
                placeholder: "sk-or-v1-...",
                binding: context.providerConfigSecretBinding(
                    key: OpenRouterSettingsReader.managementAPIKeyEnvironmentKey,
                    logField: "managementAPIKey"),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
