import CodexBarCore
import Foundation

struct MiniMaxProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .minimax

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.minimaxCookieSource
        _ = settings.minimaxCookieHeader
        _ = settings.minimaxAPIToken
        _ = settings.minimaxAPIRegion
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .minimax(context.settings.minimaxSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty {
            return true
        }
        if context.settings.minimaxAuthMode().usesAPIToken {
            return false
        }
        return context.settings.minimaxCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.minimaxCookieSource != .manual {
            settings.minimaxCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let authMode: () -> MiniMaxAuthMode = {
            context.settings.minimaxAuthMode()
        }

        let regionBinding = context.rawValueBinding(\.minimaxAPIRegion, fallback: .global)
        let regionOptions = MiniMaxAPIRegion.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }

        return [
            ProviderCookieSourceUI.picker(
                id: "minimax-cookie-source",
                context: context,
                source: \.minimaxCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: "Automatic imports browser cookies and local storage tokens.",
                        manual: "Paste a Cookie header or cURL capture from the Token Plan page.",
                        off: "MiniMax cookies are disabled.")
                },
                isVisible: { authMode().allowsCookies },
                onChange: nil,
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .minimax)
                }),
            ProviderSettingsPickerDescriptor(
                id: "minimax-region",
                title: "API region",
                subtitle: "Choose the MiniMax host (global .io or China mainland .com).",
                binding: regionBinding,
                options: regionOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        let authMode: () -> MiniMaxAuthMode = {
            context.settings.minimaxAuthMode()
        }

        return [
            ProviderSettingsFieldDescriptor(
                id: "minimax-api-token",
                title: "API token",
                subtitle: "Stored in ~/.codexbar/config.json. Paste your MiniMax API key.",
                kind: .secure,
                placeholder: "Paste API token…",
                binding: context.binding(\.minimaxAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "minimax-open-dashboard",
                        title: "Open Token Plan",
                        url: context.settings.minimaxAPIRegion.codingPlanURL),
                ],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "minimax-cookie",
                title: "Cookie header",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.binding(\.minimaxCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "minimax-open-dashboard-cookie",
                        title: "Open Token Plan",
                        url: context.settings.minimaxAPIRegion.codingPlanURL),
                ],
                isVisible: {
                    authMode().allowsCookies && context.settings.minimaxCookieSource == .manual
                }),
        ]
    }
}
