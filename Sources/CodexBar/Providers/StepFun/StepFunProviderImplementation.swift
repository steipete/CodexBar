import CodexBarCore
import Foundation

struct StepFunProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .stepfun

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.stepfunCookieSource
        _ = settings.stepfunUsername
        _ = settings.stepfunPassword
        _ = settings.stepfunToken
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        // Available if any auth method is configured
        if !context.settings.stepfunUsername.isEmpty, !context.settings.stepfunPassword.isEmpty {
            return true
        }
        if context.settings.stepfunCookieSource == .manual, !context.settings.stepfunToken.isEmpty {
            return true
        }
        if CookieHeaderCache.load(provider: .stepfun) != nil {
            return true
        }
        if StepFunSettingsReader.username(environment: context.environment) != nil,
           StepFunSettingsReader.password(environment: context.environment) != nil
        {
            return true
        }
        if StepFunSettingsReader.token(environment: context.environment) != nil {
            return true
        }
        return false
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .stepfun(context.settings.stepfunSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.stepfunCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.stepfunCookieSource != .manual {
            settings.stepfunCookieSource = .manual
        }
    }

    // MARK: - Settings Pickers

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "stepfun-cookie-source",
                context: context,
                source: \.stepfunCookieSource,
                allowsOff: true,
                subtitles: {
                    .init(
                        auto: L("Uses username + password to login and obtain an %@ automatically.", "Oasis-Token"),
                        manual: L("Manually paste an %@ from a browser session.", "Oasis-Token"),
                        off: L("%@ authentication is disabled.", "StepFun"))
                },
                title: "Auth source",
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .stepfun)
                }),
        ]
    }

    // MARK: - Settings Fields

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        // Auto mode: show username + password fields
        let autoFields: [ProviderSettingsFieldDescriptor] = [
            ProviderSettingsFieldDescriptor(
                id: "stepfun-username",
                title: "Username",
                subtitle: "StepFun platform account (phone number or email).",
                kind: .plain,
                placeholder: "user@example.com",
                binding: context.binding(\.stepfunUsername),
                actions: [],
                isVisible: { context.settings.stepfunCookieSource != .manual }),
            ProviderSettingsFieldDescriptor(
                id: "stepfun-password",
                title: "Password",
                subtitle: "Your StepFun platform password. Used to login and obtain a session token.",
                kind: .secure,
                placeholder: "Password",
                binding: context.binding(\.stepfunPassword),
                actions: [],
                isVisible: { context.settings.stepfunCookieSource != .manual }),
        ]

        // Manual mode: show token field
        let manualFields: [ProviderSettingsFieldDescriptor] = [
            ProviderSettingsFieldDescriptor(
                id: "stepfun-token",
                title: "Oasis-Token",
                subtitle: "Paste the Oasis-Token from a logged-in browser session on platform.stepfun.com.",
                kind: .secure,
                placeholder: "Oasis-Token=…",
                binding: context.binding(\.stepfunToken),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "stepfun-open-platform",
                        title: "Open StepFun Platform",
                        url: URL(string: "https://platform.stepfun.com/plan-usage")),
                ],
                isVisible: { context.settings.stepfunCookieSource == .manual }),
        ]

        return autoFields + manualFields
    }
}
