import CodexBarCore
import Foundation

struct AntigravityProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .antigravity
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        // Process detection is useful to diagnostics, but is not an installed version or a usage-source check.
        ProviderPresentation(showsVersionInSettings: false) { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.antigravityUsageDataSource
        _ = settings.antigravityPrioritizeExhaustedQuotas
        _ = settings.tokenAccountsData(for: .antigravity)
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.antigravityUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.antigravityUsageDataSource {
        case .auto: .auto
        case .oauth: .oauth
        case .cli: .cli
        }
    }

    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        [
            ProviderSettingsToggleDescriptor(
                id: "antigravity-prioritize-exhausted-quotas",
                title: "Prioritize exhausted quotas",
                subtitle: "Optional. In Automatic mode, let exhausted five-hour or weekly lanes outrank " +
                    "still-usable model families. Applies to the menu bar and Overview ranking.",
                binding: context.binding(\.antigravityPrioritizeExhaustedQuotas),
                statusText: nil,
                actions: [],
                isVisible: nil,
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
        ]
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderSettingsPickerDescriptor(
                id: "antigravity-usage-source",
                title: "Usage source",
                subtitle: "Auto skips agy reports without account identity for selected or injected Google accounts. " +
                    "Try Local API / agy CLI to use the local app or agy's signed-in account, which may differ.",
                binding: context.rawValueBinding(\.antigravityUsageDataSource, fallback: .auto),
                options: AntigravityUsageDataSource.allCases.map {
                    ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
                },
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.antigravityUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .antigravity)
                    return label == "auto" ? nil : label
                }),
        ]
    }

    @MainActor
    func settingsActions(context: ProviderSettingsContext) -> [ProviderSettingsActionsDescriptor] {
        let accountCount = context.settings.tokenAccounts(for: .antigravity).count
        let loginTitle = accountCount > 0 ? "Add Google Account" : "Login with Google"
        let subtitle = """
        Stores each signed-in Google account for quick Antigravity switching. \
        Uses Antigravity.app OAuth when available, \
        or ANTIGRAVITY_OAUTH_CLIENT_ID and ANTIGRAVITY_OAUTH_CLIENT_SECRET as an override.
        """
        return [
            ProviderSettingsActionsDescriptor(
                id: "antigravity-oauth",
                title: "Google OAuth",
                subtitle: subtitle,
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "antigravity-oauth-login",
                        title: loginTitle,
                        style: .bordered,
                        isVisible: nil,
                        perform: {
                            await context.runLoginFlow()
                        }),
                ],
                isVisible: nil),
        ]
    }

    func detectVersion(context _: ProviderVersionContext) async -> String? {
        await AntigravityStatusProbe.detectVersion()
    }

    @MainActor
    func loginMenuAction(context _: ProviderMenuLoginContext) -> (label: String, action: MenuDescriptor.MenuAction)? {
        ("Add Account...", .switchAccount(.antigravity))
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runAntigravityLoginFlow()
        return false
    }
}
