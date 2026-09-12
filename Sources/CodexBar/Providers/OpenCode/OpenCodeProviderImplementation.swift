import CodexBarCore
import Foundation

struct OpenCodeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .opencode

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.opencodeCookieSource
        _ = settings.opencodeCookieHeader
        _ = settings.opencodeWorkspaceID
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .opencode(context.settings.opencodeSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty {
            return true
        }
        return context.settings.opencodeCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.opencodeCookieSource != .manual {
            settings.opencodeCookieSource = .manual
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "opencode-cookie-source",
                context: context,
                source: \.opencodeCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: "Automatic imports browser cookies from opencode.ai.",
                        manual: "Paste a Cookie header captured from the billing page.",
                        off: "OpenCode cookies are disabled.")
                },
                trailingText: {
                    ProviderCookieRefreshAction.trailingText(
                        provider: .opencode,
                        cookieSource: context.settings.opencodeCookieSource,
                        context: context)
                },
                trailingActions: [
                    ProviderCookieRefreshAction.descriptor(
                        provider: .opencode,
                        cookieSource: { context.settings.opencodeCookieSource },
                        context: context),
                ]),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "opencode-workspace-id",
                title: "Workspace ID",
                subtitle: "Optional override if workspace lookup fails.",
                kind: .plain,
                placeholder: "wrk_…",
                binding: context.binding(\.opencodeWorkspaceID),
                actions: [],
                isVisible: nil),
        ]
    }
}
