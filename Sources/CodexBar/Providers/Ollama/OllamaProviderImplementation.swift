import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct OllamaProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .ollama

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.ollamaUsageDataSource
        _ = settings.ollamaAPIToken
        _ = settings.ollamaCookieSource
        _ = settings.ollamaCookieHeader
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.ollamaUsageDataSource
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if OllamaAPISettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        context.settings.ensureOllamaAPITokenLoaded()
        if !context.settings.ollamaAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return context.settings.ollamaCookieSource != .off
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .ollama(context.settings.ollamaSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.ollamaCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.ollamaCookieSource != .manual {
            settings.ollamaCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let sourceBinding = Binding(
            get: { context.settings.ollamaUsageDataSource.rawValue },
            set: { raw in
                context.settings.ollamaUsageDataSource = ProviderSourceMode(rawValue: raw) ?? .auto
            })
        let sourceOptions: [ProviderSettingsPickerOption] = [
            ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.api.rawValue, title: "API key"),
        ]
        let cookieBinding = Binding(
            get: { context.settings.ollamaCookieSource.rawValue },
            set: { raw in
                context.settings.ollamaCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.ollamaCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies.",
                manual: "Paste a Cookie header or cURL capture from Ollama settings.",
                off: "Ollama cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "ollama-usage-source",
                title: "Usage source",
                subtitle: "API key verifies Ollama Cloud access; cookies still expose quota limits.",
                binding: sourceBinding,
                options: sourceOptions,
                isVisible: nil,
                onChange: nil),
            ProviderSettingsPickerDescriptor(
                id: "ollama-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "ollama-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Get your key from Ollama settings.",
                kind: .secure,
                placeholder: "ollama-...",
                binding: context.stringBinding(\.ollamaAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "ollama-open-api-keys",
                        title: "Open Ollama API Keys",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://ollama.com/settings/keys") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureOllamaAPITokenLoaded() }),
            ProviderSettingsFieldDescriptor(
                id: "ollama-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.ollamaCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "ollama-open-settings",
                        title: "Open Ollama Settings",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://ollama.com/settings") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.ollamaCookieSource == .manual },
                onActivate: { context.settings.ensureOllamaCookieLoaded() }),
        ]
    }
}
