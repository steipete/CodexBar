import CodexBarCore
import SwiftUI

struct ClaudeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .claude
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            var versionText = context.store.version(for: context.provider) ?? "not detected"
            if let parenRange = versionText.range(of: "(") {
                versionText = versionText[..<parenRange.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            return "\(context.metadata.cliName) \(versionText)"
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.claudeUsageDataSource
        _ = settings.claudeAdminAPIKey
        _ = settings.claudeCookieSource
        _ = settings.claudeCookieHeader
        _ = settings.claudeOAuthKeychainPromptMode
        _ = settings.claudeOAuthKeychainReadStrategy
        _ = settings.claudeWebExtrasEnabled
        _ = settings.claudeSwapEnabled
        _ = settings.claudeSwapExecutablePath
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

    func makeRuntime() -> (any ProviderRuntime)? {
        ClaudeProviderRuntime()
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.claudeUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.claudeUsageDataSource {
        case .auto: .auto
        case .api: .api
        case .oauth: .oauth
        case .web: .web
        case .cli: .cli
        }
    }

    @MainActor
    func settingsToggles(context: ProviderSettingsContext) -> [ProviderSettingsToggleDescriptor] {
        let subtitle = if context.settings.debugDisableKeychainAccess {
            "Inactive while \"Disable Keychain access\" is enabled in Advanced."
        } else {
            "Never allow Claude OAuth credential reads to show macOS Keychain prompts."
        }

        let promptFreeBinding = Binding(
            get: { context.settings.claudeOAuthPromptFreeCredentialsEnabled },
            set: { enabled in
                guard !context.settings.debugDisableKeychainAccess else { return }
                context.settings.claudeOAuthPromptFreeCredentialsEnabled = enabled
            })

        let claudeSwapBinding = Binding(
            get: { context.settings.claudeSwapEnabled },
            set: { context.settings.claudeSwapEnabled = $0 })

        return [
            ProviderSettingsToggleDescriptor(
                id: "claude-oauth-prompt-free-credentials",
                title: "Avoid Keychain prompts",
                subtitle: subtitle,
                binding: promptFreeBinding,
                statusText: nil,
                actions: [],
                isVisible: nil,
                isEnabled: { !context.settings.debugDisableKeychainAccess },
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
            ProviderSettingsToggleDescriptor(
                id: "claude-swap-accounts",
                title: "Read accounts from claude-swap",
                subtitle: "Shows usage and lets you switch accounts through `cswap`. " +
                    "Credentials stay managed by claude-swap; CodexBar never reads them.",
                binding: claudeSwapBinding,
                statusText: { Self.claudeSwapStatusText(store: context.store, settings: context.settings) },
                actions: [],
                isVisible: nil,
                isEnabled: nil,
                onChange: nil,
                onAppDidBecomeActive: nil,
                onAppearWhenEnabled: nil),
        ]
    }

    @MainActor
    private static func claudeSwapStatusText(store: UsageStore, settings: SettingsStore) -> String? {
        guard settings.claudeSwapEnabled else { return nil }
        if settings.claudeSwapExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Set the cswap executable path below."
        }
        var parts: [String] = []
        if let version = store.claudeSwapDetectedVersion {
            parts.append("claude-swap \(version)")
        }
        if let error = store.claudeSwapLastError {
            parts.append(error)
        } else if let refreshedAt = store.claudeSwapLastRefreshAt {
            let accounts = store.claudeSwapAccountSnapshots.count
            let accountsText = accounts == 1 ? "1 account" : "\(accounts) accounts"
            parts.append("\(accountsText), updated \(refreshedAt.relativeDescription())")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
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
                title: "Never prompt"),
            ProviderSettingsPickerOption(
                id: ClaudeOAuthKeychainPromptMode.onlyOnUserAction.rawValue,
                title: "Only on user action"),
            ProviderSettingsPickerOption(
                id: ClaudeOAuthKeychainPromptMode.always.rawValue,
                title: "Always allow prompts"),
        ]
        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.claudeCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies for the web API.",
                manual: "Paste a Cookie header from a claude.ai request.",
                off: "Claude cookies are disabled.")
        }
        let keychainPromptPolicySubtitle: () -> String? = {
            if context.settings.debugDisableKeychainAccess {
                return "Global Keychain access is disabled in Advanced, so this setting is currently inactive."
            }
            return "Choosing \"Never prompt\" can make OAuth unavailable; use Web/CLI when needed."
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
                id: "claude-keychain-prompt-policy",
                title: "Keychain prompt policy",
                subtitle: "Controls when Claude OAuth may ask macOS for Keychain access.",
                dynamicSubtitle: keychainPromptPolicySubtitle,
                binding: keychainPromptPolicyBinding,
                options: keychainPromptPolicyOptions,
                isVisible: nil,
                isEnabled: { !context.settings.debugDisableKeychainAccess },
                onChange: nil),
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
                    ProviderCookieSourceUI.cachedTrailingText(provider: .claude)
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "claude-admin-api-key",
                title: "Admin API key",
                subtitle: "Stored in ~/.codexbar/config.json. Requires an Anthropic Admin API key.",
                kind: .secure,
                placeholder: "sk-ant-admin...",
                binding: context.stringBinding(\.claudeAdminAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "claude-swap-executable-path",
                title: "claude-swap executable",
                subtitle: "Path to the cswap executable (github.com/realiti4/claude-swap).",
                kind: .plain,
                placeholder: "~/.local/bin/cswap",
                binding: context.stringBinding(\.claudeSwapExecutablePath),
                actions: [],
                isVisible: { context.settings.claudeSwapEnabled },
                onActivate: nil),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runClaudeLoginFlow()
    }

    @MainActor
    func appendUsageMenuEntries(context: ProviderMenuUsageContext, entries: inout [ProviderMenuEntry]) {
        if context.snapshot?.secondary == nil {
            entries.append(.text(L("Weekly usage unavailable for this account."), .secondary))
        }

        if let cost = context.snapshot?.providerCost,
           context.settings.showOptionalCreditsAndExtraUsage,
           cost.currencyCode != "Quota"
        {
            let used = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            let limit = UsageFormatter.currencyString(cost.limit, currencyCode: cost.currencyCode)
            entries.append(.text(String(format: L("extra_usage_format"), used, limit), .primary))
        }
    }

    @MainActor
    func loginMenuAction(context: ProviderMenuLoginContext)
        -> (label: String, action: MenuDescriptor.MenuAction)?
    {
        if self.shouldOpenBrowserForWebSessionError(context: context) {
            return ("Re-login at claude.ai", .loginToProvider(url: "https://claude.ai/"))
        }
        if self.shouldOpenTerminalForOAuthError(store: context.store) {
            return ("Open Terminal", .openTerminal(command: "claude"))
        }
        return (L("Sign in with Claude Code..."), .switchAccount(.claude))
    }

    @MainActor
    private func shouldOpenBrowserForWebSessionError(context: ProviderMenuLoginContext) -> Bool {
        let settings = context.settings.claudeSettingsSnapshot(tokenOverride: nil)
        let source = settings.usageDataSource
        guard source == .auto || source == .web,
              settings.cookieSource == .auto,
              let error = context.store.error(for: .claude)
        else { return false }

        let sessionErrors = [
            ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription,
            ClaudeWebAPIFetcher.FetchError.noSessionKeyFound.localizedDescription,
            ClaudeWebAPIFetcher.FetchError.invalidSessionKey.localizedDescription,
        ]
        if sessionErrors.contains(error) {
            return true
        }

        guard error == ProviderFetchError.noAvailableStrategy(.claude).localizedDescription else { return false }
        return context.store.fetchAttempts(for: .claude).contains {
            $0.strategyID == "claude.web" && !$0.wasAvailable
        }
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
