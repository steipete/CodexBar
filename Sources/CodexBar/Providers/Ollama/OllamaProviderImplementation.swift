import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct OllamaProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .ollama

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.ollamaCookieSource
        _ = settings.ollamaCookieHeader
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
                auto: L10n.tr("Automatic imports browser cookies."),
                manual: L10n.tr("Paste a Cookie header or cURL capture from Ollama settings."),
                off: L10n.tr("Ollama cookies are disabled."))
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "ollama-cookie-source",
                title: L10n.tr("Cookie source"),
                subtitle: L10n.tr("Automatic imports browser cookies."),
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
                id: "ollama-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: L10n.tr("Cookie: ..."),
                binding: context.stringBinding(\.ollamaCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "ollama-open-settings",
                        title: L10n.tr("Open Ollama Settings"),
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
