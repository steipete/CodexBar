import CodexBarCore
import CodexBarMacroSupport
import SwiftUI

@ProviderImplementationRegistration
struct ClaudeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .claude
    let supportsLoginFlow: Bool = true

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = Binding(
            get: { context.settings.claudeUsageDataSource.rawValue },
            set: { raw in
                context.settings.claudeUsageDataSource = ClaudeUsageDataSource(rawValue: raw) ?? .auto
            })
        let cookieBinding = Binding(
            get: { context.settings.claudeCookieSource.rawValue },
            set: { raw in
                context.settings.claudeCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })

        let usageOptions = ClaudeUsageDataSource.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.claudeCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies for the web API.",
                manual: "Paste a Cookie header from a claude.ai request.",
                off: "Claude cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "claude-usage-source",
                title: "Usage source",
                subtitle: "Auto falls back to the next source if the preferred one fails.",
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.claudeUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .claude)
                    return label == "auto" ? nil : label
                }),
            ProviderSettingsPickerDescriptor(
                id: "claude-cookie-source",
                title: "Claude cookies",
                subtitle: "Automatic imports browser cookies for the web API.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .claude) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        _ = context
        return []
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runClaudeLoginFlow()
        return true
    }
}
