import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct CodexProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .codex
    let supportsLoginFlow: Bool = true

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = Binding(
            get: { context.settings.codexUsageDataSource.rawValue },
            set: { raw in
                context.settings.codexUsageDataSource = CodexUsageDataSource(rawValue: raw) ?? .auto
            })
        let cookieBinding = Binding(
            get: { context.settings.codexCookieSource.rawValue },
            set: { raw in
                context.settings.codexCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })

        let usageOptions = CodexUsageDataSource.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.codexCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies for dashboard extras.",
                manual: "Paste a Cookie header from a chatgpt.com request.",
                off: "Disable OpenAI dashboard cookie usage.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "codex-usage-source",
                title: "Usage source",
                subtitle: "Auto falls back to the next source if the preferred one fails.",
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.codexUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .codex)
                    return label == "auto" ? nil : label
                }),
            ProviderSettingsPickerDescriptor(
                id: "codex-cookie-source",
                title: "OpenAI cookies",
                subtitle: "Automatic imports browser cookies for dashboard extras.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .codex) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "codex-cookie-header",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.codexCookieHeader),
                actions: [],
                isVisible: {
                    context.settings.codexCookieSource == .manual
                },
                onActivate: { context.settings.ensureCodexCookieLoaded() }),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runCodexLoginFlow()
        return true
    }
}
