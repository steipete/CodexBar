import CodexBarCore
import Foundation
import SwiftUI

struct MistralProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .mistral

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { $0.store.sourceLabel(for: self.id) }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.providerConfig(for: self.id)?.source
        _ = settings.mistralCookieSource
        _ = settings.mistralCookieHeader
        _ = settings.mistralAPIKey
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        Self.normalizedSourceMode(context.settings.providerConfig(for: self.id)?.source).rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        Self.normalizedSourceMode(context.settings.providerConfig(for: self.id)?.source)
    }

    private static func normalizedSourceMode(_ source: ProviderSourceMode?) -> ProviderSourceMode {
        switch source {
        case .api: .api
        case .web: .web
        case .auto, .cli, .oauth, nil: .auto
        }
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.mistralCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.mistralCookieSource != .manual {
            settings.mistralCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageSource = ProviderSettingsPickerDescriptor(
            id: "mistral-usage-source",
            title: "Usage source",
            subtitle: "Auto tries the API key first and falls back to browser cookies. "
                + "Browser cookies are required for spend, credits, and token history.",
            binding: Binding(
                get: { Self.normalizedSourceMode(context.settings.providerConfig(for: self.id)?.source).rawValue },
                set: { raw in
                    let mode = Self.normalizedSourceMode(ProviderSourceMode(rawValue: raw))
                    guard mode != (context.settings.providerConfig(for: self.id)?.source ?? .auto) else { return }
                    context.store.clearProviderState(self.id)
                    context.settings.updateProviderConfig(provider: self.id) { $0.source = mode }
                }),
            options: [
                .init(id: "auto", title: "Auto"),
                .init(id: "api", title: "API key"),
                .init(id: "web", title: "Browser cookies"),
            ],
            isVisible: nil,
            onChange: nil)
        return [usageSource, self.cookiePicker(context: context)]
    }

    @MainActor
    private func cookiePicker(context: ProviderSettingsContext) -> ProviderSettingsPickerDescriptor {
        ProviderCookieSourceUI.picker(
            id: "mistral-cookie-source",
            context: context,
            source: \.mistralCookieSource,
            allowsOff: true,
            subtitles: {
                .init(
                    auto: L("Automatic imports browser cookies from admin.mistral.ai."),
                    manual: L("Paste a Cookie header captured from %@.", "the billing page"),
                    off: L("%@ cookies are disabled.", "Mistral"))
            },
            isVisible: { context.settings.providerConfig(for: self.id)?.source != .api },
            trailingText: {
                ProviderCookieRefreshAction.trailingText(
                    provider: .mistral,
                    cookieSource: context.settings.mistralCookieSource,
                    context: context)
            },
            trailingActions: [
                ProviderCookieRefreshAction.descriptor(
                    provider: .mistral,
                    cookieSource: { context.settings.mistralCookieSource },
                    browserOnly: true,
                    context: context),
            ])
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "mistral-api-key",
                title: "API key",
                subtitle: "Optional. Reads included API and Vibe allowances without browser cookies.",
                kind: .secure,
                placeholder: "API key",
                binding: context.binding(\.mistralAPIKey),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "mistral-open-api-keys",
                        title: "Open API keys",
                        url: URL(string: "https://console.mistral.ai/api-keys")),
                ],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "mistral-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a request to admin.mistral.ai. "
                    + "Must contain an ory_session_* cookie.",
                kind: .secure,
                placeholder: "ory_session_…=…; csrftoken=…",
                binding: context.binding(\.mistralCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "mistral-open-console",
                        title: "Open Mistral Admin",
                        url: URL(string: "https://admin.mistral.ai/organization/usage")),
                ],
                isVisible: { context.settings.mistralCookieSource == .manual
                    && context.settings.providerConfig(for: self.id)?.source != .api
                }),
        ]
    }
}
