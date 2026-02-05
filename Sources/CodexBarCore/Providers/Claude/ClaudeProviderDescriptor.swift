import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum ClaudeProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .claude,
            metadata: ProviderMetadata(
                id: .claude,
                displayName: "Claude",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: "Sonnet",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Claude Code usage",
                cliName: "claude",
                defaultEnabled: false,
                isPrimaryProvider: true,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://console.anthropic.com/settings/billing",
                subscriptionDashboardURL: "https://claude.ai/settings/usage",
                statusPageURL: "https://status.claude.com/"),
            branding: ProviderBranding(
                iconStyle: .claude,
                iconResourceName: "ProviderIcon-claude",
                color: ProviderColor(red: 204 / 255, green: 124 / 255, blue: 94 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: self.noDataMessage),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .cli, .oauth],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "claude",
                versionDetector: { browserDetection in
                    ClaudeUsageFetcher(browserDetection: browserDetection).detectVersion()
                }))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.runtime {
        case .cli:
            switch context.sourceMode {
            case .oauth:
                return [ClaudeOAuthFetchStrategy()]
            case .web:
                return [ClaudeWebFetchStrategy(browserDetection: context.browserDetection)]
            case .cli:
                return [ClaudeCLIFetchStrategy(
                    useWebExtras: false,
                    manualCookieHeader: nil,
                    browserDetection: context.browserDetection)]
            case .api:
                return []
            case .auto:
                return [
                    ClaudeWebFetchStrategy(browserDetection: context.browserDetection),
                    ClaudeCLIFetchStrategy(
                        useWebExtras: false,
                        manualCookieHeader: nil,
                        browserDetection: context.browserDetection),
                ]
            }
        case .app:
            let webExtrasEnabled = context.settings?.claude?.webExtrasEnabled ?? false
            let manualCookieHeader = CookieHeaderNormalizer.normalize(context.settings?.claude?.manualCookieHeader)
            switch context.sourceMode {
            case .oauth:
                return [
                    ClaudeOAuthFetchStrategy(),
                    ClaudeWebFetchStrategy(browserDetection: context.browserDetection),
                    ClaudeCLIFetchStrategy(
                        useWebExtras: webExtrasEnabled,
                        manualCookieHeader: manualCookieHeader,
                        browserDetection: context.browserDetection),
                ]
            case .web:
                return [ClaudeWebFetchStrategy(browserDetection: context.browserDetection)]
            case .cli:
                return [ClaudeCLIFetchStrategy(
                    useWebExtras: webExtrasEnabled,
                    manualCookieHeader: manualCookieHeader,
                    browserDetection: context.browserDetection)]
            case .api:
                return []
            case .auto:
                return [
                    ClaudeOAuthFetchStrategy(),
                    ClaudeWebFetchStrategy(browserDetection: context.browserDetection),
                    ClaudeCLIFetchStrategy(
                        useWebExtras: webExtrasEnabled,
                        manualCookieHeader: manualCookieHeader,
                        browserDetection: context.browserDetection),
                ]
            }
        }
    }

    private static func noDataMessage() -> String {
        "No Claude usage logs found in ~/.config/claude/projects or ~/.claude/projects."
    }

    public static func resolveUsageStrategy(
        selectedDataSource: ClaudeUsageDataSource,
        webExtrasEnabled: Bool,
        hasWebSession: Bool,
        hasOAuthCredentials: Bool) -> ClaudeUsageStrategy
    {
        if selectedDataSource == .auto {
            if hasOAuthCredentials {
                return ClaudeUsageStrategy(dataSource: .oauth, useWebExtras: false)
            }
            if hasWebSession {
                return ClaudeUsageStrategy(dataSource: .web, useWebExtras: false)
            }
            return ClaudeUsageStrategy(dataSource: .cli, useWebExtras: false)
        }

        let useWebExtras = selectedDataSource == .cli && webExtrasEnabled && hasWebSession
        return ClaudeUsageStrategy(dataSource: selectedDataSource, useWebExtras: useWebExtras)
    }
}

public struct ClaudeUsageStrategy: Equatable, Sendable {
    public let dataSource: ClaudeUsageDataSource
    public let useWebExtras: Bool
}

struct ClaudeOAuthFetchStrategy: ProviderFetchStrategy {
    let id: String = "claude.oauth"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let shouldApplyOAuthRefreshFailureGate = context.runtime == .app
            && (context.sourceMode == .auto || context.sourceMode == .oauth)
        let hasEnvironmentOAuthToken = !(context.env[ClaudeOAuthCredentialsStore.environmentTokenKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
        if shouldApplyOAuthRefreshFailureGate, !hasEnvironmentOAuthToken {
            guard ClaudeOAuthRefreshFailureGate.shouldAttempt() else { return false }
        }
        // In OAuth-only mode, allow the fetch to run (and prompt when needed) unless:
        // - refresh is terminal-blocked due to an auth-specific rejection (e.g. invalid_grant), or
        // - refresh is transiently backed off due to repeated 400/401 failures.
        guard context.sourceMode == .auto else { return true }

        // Prefer OAuth in Auto mode only when it’s plausibly usable:
        // - we can load credentials without prompting (env / CodexBar cache / credentials file) AND they meet the
        //   scope requirement, or
        // - Claude Code has stored OAuth creds in Keychain and we may be able to bootstrap (one prompt max).
        if let creds = try? ClaudeOAuthCredentialsStore.load(
            environment: context.env,
            allowKeychainPrompt: false,
            respectKeychainPromptCooldown: true)
        {
            let hasRequiredScope = creds.scopes.contains("user:profile")
            if hasRequiredScope {
                if !creds.isExpired { return true }
                let refreshToken = creds.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !refreshToken.isEmpty { return true }
            }
        }
        guard ClaudeOAuthKeychainAccessGate.shouldAllowPrompt() else { return false }
        return ClaudeOAuthCredentialsStore.hasClaudeKeychainCredentialsWithoutPrompt()
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = ClaudeUsageFetcher(
            browserDetection: context.browserDetection,
            environment: context.env,
            dataSource: .oauth,
            oauthKeychainPromptCooldownEnabled: context.sourceMode == .auto,
            useWebExtras: false)
        let usage = try await fetcher.loadLatestUsage(model: "sonnet")
        return self.makeResult(
            usage: Self.snapshot(from: usage),
            sourceLabel: "oauth")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        // In Auto mode, fall back to CLI if OAuth fails (e.g. user cancels keychain prompt or auth breaks).
        // In OAuth-only mode, allow Web/CLI fallback as a safety net.
        context.runtime == .app && (context.sourceMode == .oauth || context.sourceMode == .auto)
    }

    fileprivate static func snapshot(from usage: ClaudeUsageSnapshot) -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: usage.accountEmail,
            accountOrganization: usage.accountOrganization,
            loginMethod: usage.loginMethod)
        return UsageSnapshot(
            primary: usage.primary,
            secondary: usage.secondary,
            tertiary: usage.opus,
            providerCost: usage.providerCost,
            updatedAt: usage.updatedAt,
            identity: identity)
    }
}

struct ClaudeWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "claude.web"
    let kind: ProviderFetchKind = .web
    let browserDetection: BrowserDetection

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if let header = Self.manualCookieHeader(from: context) {
            return ClaudeWebAPIFetcher.hasSessionKey(cookieHeader: header)
        }
        guard context.settings?.claude?.cookieSource != .off else { return false }
        return ClaudeWebAPIFetcher.hasSessionKey(browserDetection: self.browserDetection)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = ClaudeUsageFetcher(
            browserDetection: browserDetection,
            dataSource: .web,
            useWebExtras: false,
            manualCookieHeader: Self.manualCookieHeader(from: context))
        let usage = try await fetcher.loadLatestUsage(model: "sonnet")
        return self.makeResult(
            usage: ClaudeOAuthFetchStrategy.snapshot(from: usage),
            sourceLabel: "web")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        _ = error
        return true
    }

    private static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.claude?.cookieSource == .manual else { return nil }
        return CookieHeaderNormalizer.normalize(context.settings?.claude?.manualCookieHeader)
    }
}

struct ClaudeCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "claude.cli"
    let kind: ProviderFetchKind = .cli
    let useWebExtras: Bool
    let manualCookieHeader: String?
    let browserDetection: BrowserDetection

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let keepAlive = context.settings?.debugKeepCLISessionsAlive ?? false
        let fetcher = ClaudeUsageFetcher(
            browserDetection: browserDetection,
            dataSource: .cli,
            useWebExtras: self.useWebExtras,
            manualCookieHeader: self.manualCookieHeader,
            keepCLISessionsAlive: keepAlive)
        let usage = try await fetcher.loadLatestUsage(model: "sonnet")
        return self.makeResult(
            usage: ClaudeOAuthFetchStrategy.snapshot(from: usage),
            sourceLabel: "claude")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        false
    }
}
