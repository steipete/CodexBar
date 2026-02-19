import CodexBarCore
import CodexBarMacroSupport
import SwiftUI

@ProviderImplementationRegistration
struct ClaudeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .claude
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            var versionText = context.store.version(for: context.provider) ?? L10n.tr("not detected")
            if let parenRange = versionText.range(of: "(") {
                versionText = versionText[..<parenRange.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            versionText = L10n.localizedDynamicValue(versionText)
            if versionText == L10n.tr("not detected") {
                return L10n.format("Provider detail missing: %@ %@", context.metadata.displayName, versionText)
            }
            return L10n.format("Provider detail: %@ %@", context.metadata.displayName, versionText)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.claudeUsageDataSource
        _ = settings.claudeCookieSource
        _ = settings.claudeCookieHeader
        _ = settings.claudeOAuthKeychainPromptMode
        _ = settings.claudeOAuthKeychainReadStrategy
        _ = settings.claudeWebExtrasEnabled
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .claude(context.settings.claudeSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        guard support.requiresManualCookieSource else { return true }
        if !context.settings.tokenAccounts(for: context.provider).isEmpty { return true }
        return context.settings.claudeCookieSource == .manual
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        if settings.claudeCookieSource != .manual {
            settings.claudeCookieSource = .manual
        }
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.claudeUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.claudeUsageDataSource {
        case .auto: .auto
        case .oauth: .oauth
        case .web: .web
        case .cli: .cli
        }
    }

    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        let subtitle = if context.settings.debugDisableKeychainAccess {
            L10n.tr("Inactive while \"Disable Keychain access\" is enabled in Advanced.")
        } else {
            L10n.tr("Use /usr/bin/security to read Claude credentials and avoid CodexBar keychain prompts.")
        }

        let promptFreeBinding = Binding(
            get: { context.settings.claudeOAuthPromptFreeCredentialsEnabled },
            set: { enabled in
                guard !context.settings.debugDisableKeychainAccess else { return }
                context.settings.claudeOAuthPromptFreeCredentialsEnabled = enabled
            })

        return [
            ProviderSettingsToggleDescriptor(
                id: "claude-oauth-prompt-free-credentials",
                title: L10n.tr("Avoid Keychain prompts (experimental)"),
                subtitle: subtitle,
                binding: promptFreeBinding,
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
        let keychainPromptPolicyBinding = Binding(
            get: { context.settings.claudeOAuthKeychainPromptMode.rawValue },
            set: { raw in
                context.settings.claudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptMode(rawValue: raw)
                    ?? .onlyOnUserAction
            })

        let usageOptions = ClaudeUsageDataSource.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let keychainPromptPolicyOptions: [ProviderSettingsPickerOption] = [
            ProviderSettingsPickerOption(
                id: ClaudeOAuthKeychainPromptMode.never.rawValue,
                title: L10n.tr("Never prompt")),
            ProviderSettingsPickerOption(
                id: ClaudeOAuthKeychainPromptMode.onlyOnUserAction.rawValue,
                title: L10n.tr("Only on user action")),
            ProviderSettingsPickerOption(
                id: ClaudeOAuthKeychainPromptMode.always.rawValue,
                title: L10n.tr("Always allow prompts")),
        ]
        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.claudeCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: L10n.tr("Automatic imports browser cookies for the web API."),
                manual: L10n.tr("Paste a Cookie header from a claude.ai request."),
                off: L10n.tr("Claude cookies are disabled."))
        }
        let keychainPromptPolicySubtitle: () -> String? = {
            if context.settings.debugDisableKeychainAccess {
                return L10n.tr("Global Keychain access is disabled in Advanced, so this setting is currently inactive.")
            }
            return L10n.tr(
                "Controls Claude OAuth Keychain prompts when experimental reader mode is off. Choosing \"Never prompt\" can make OAuth unavailable; use Web/CLI when needed.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "claude-usage-source",
                title: L10n.tr("Usage source"),
                subtitle: L10n.tr("Auto falls back to the next source if the preferred one fails."),
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
                id: "claude-keychain-prompt-policy",
                title: L10n.tr("Keychain prompt policy"),
                subtitle: L10n.tr("Applies only to the Security.framework OAuth keychain reader."),
                dynamicSubtitle: keychainPromptPolicySubtitle,
                binding: keychainPromptPolicyBinding,
                options: keychainPromptPolicyOptions,
                isVisible: { context.settings.claudeOAuthKeychainReadStrategy == .securityFramework },
                isEnabled: { !context.settings.debugDisableKeychainAccess },
                onChange: nil),
            ProviderSettingsPickerDescriptor(
                id: "claude-cookie-source",
                title: L10n.tr("Claude cookies"),
                subtitle: L10n.tr("Automatic imports browser cookies for the web API."),
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .claude) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return L10n.format("Cached: %@ • %@", entry.sourceLabel, when)
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

    @MainActor
    func appendUsageMenuEntries(context: ProviderMenuUsageContext, entries: inout [ProviderMenuEntry]) {
        if context.snapshot?.secondary == nil {
            entries.append(.text(L10n.tr("Weekly usage unavailable for this account."), .secondary))
        }

        if let cost = context.snapshot?.providerCost,
           context.settings.showOptionalCreditsAndExtraUsage,
           cost.currencyCode != "Quota"
        {
            let used = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            let limit = UsageFormatter.currencyString(cost.limit, currencyCode: cost.currencyCode)
            entries.append(.text(L10n.format("Extra usage: %@ / %@", used, limit), .primary))
        }
    }

    @MainActor
    func loginMenuAction(context: ProviderMenuLoginContext)
        -> (label: String, action: MenuDescriptor.MenuAction)?
    {
        guard self.shouldOpenTerminalForOAuthError(store: context.store) else { return nil }
        return (L10n.tr("Open Terminal"), .openTerminal(command: "claude"))
    }

    @MainActor
    private func shouldOpenTerminalForOAuthError(store: UsageStore) -> Bool {
        guard store.error(for: .claude) != nil else { return false }
        let attempts = store.fetchAttempts(for: .claude)
        if attempts.contains(where: { $0.kind == .oauth && ($0.errorDescription?.isEmpty == false) }) {
            return true
        }
        if let error = store.error(for: .claude)?.lowercased(), error.contains("oauth") {
            return true
        }
        return false
    }
}
