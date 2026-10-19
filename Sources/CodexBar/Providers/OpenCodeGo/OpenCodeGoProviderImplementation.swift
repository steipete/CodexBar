import CodexBarCore
import Foundation

struct OpenCodeGoProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .opencodego

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.providerConfig(for: .opencodego)?.source?.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.providerConfig(for: .opencodego)?.source ?? .auto
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.opencodegoCookieSource
        _ = settings.opencodegoCookieHeader
        _ = settings.opencodegoWorkspaceID
        _ = settings[providerConfig: .opencodego, field: .apiKey]
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .opencodego(context.settings.opencodegoSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context _: ProviderSettingsContext, support _: TokenAccountSupport) -> Bool {
        true
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        guard let account = settings.selectedTokenAccount(for: .opencodego),
              TokenAccountSupportCatalog.envOverride(for: .opencodego, token: account.token) == nil
        else { return }
        if settings.opencodegoCookieSource != .manual {
            settings.opencodegoCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "opencodego-cookie-source",
                context: context,
                source: \.opencodegoCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatic imports browser cookies from opencode.ai."),
                        manual: L("Paste a Cookie header captured from %@.", "the billing page"),
                        off: L("%@ cookies are disabled.", "OpenCode Go"))
                },
                trailingText: {
                    ProviderCookieRefreshAction.trailingText(
                        provider: .opencodego,
                        cookieSource: context.settings.opencodegoCookieSource,
                        context: context)
                },
                trailingActions: [
                    ProviderCookieRefreshAction.descriptor(
                        provider: .opencodego,
                        cookieSource: { context.settings.opencodegoCookieSource },
                        context: context),
                ]),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "opencodego-api-key",
                title: "API key",
                subtitle: "Preferred for Go usage limits. Also reads OPENCODE_API_KEY.",
                kind: .secure,
                placeholder: "OpenCode API key",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "opencodego-workspace-id",
                title: "Workspace ID",
                subtitle: "Optional override if workspace lookup fails.",
                kind: .plain,
                placeholder: "wrk_…",
                binding: context.binding(\.opencodegoWorkspaceID),
                actions: [],
                isVisible: nil),
        ]
    }
}
