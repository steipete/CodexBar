import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum StepFunProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .stepfun,
            metadata: ProviderMetadata(
                id: .stepfun,
                displayName: "StepFun",
                sessionLabel: "5h Window",
                weeklyLabel: "Weekly Window",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show StepFun usage",
                cliName: "stepfun",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://platform.stepfun.com/plan-usage",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .stepfun,
                iconResourceName: "ProviderIcon-stepfun",
                color: ProviderColor(red: 0.13, green: 0.59, blue: 0.95)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "StepFun per-day cost history is not available via API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [StepFunWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "stepfun",
                aliases: ["step-fun", "sf"],
                versionDetector: nil))
    }
}

struct StepFunWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "stepfun.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.settings?.stepfun?.cookieSource != .off
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        do {
            let resolved = try await Self.resolveToken(context: context, allowCached: true)
            let usage = try await StepFunUsageFetcher.fetchUsage(token: resolved.token)
            return self.makeResult(
                usage: usage.toUsageSnapshot(),
                sourceLabel: "web")
        } catch let error where Self.isAuthenticationFailure(error) {
            return try await self.recoverFromAuthenticationFailure(context: context, originalError: error)
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    // MARK: - Token Resolution

    private struct ResolvedToken {
        let token: String
        let source: TokenSource
    }

    private enum TokenSource {
        case manual
        case cached
        case settingsLogin
        case environmentToken
        case environmentLogin
    }

    private static func resolveToken(
        context: ProviderFetchContext,
        allowCached: Bool) async throws -> ResolvedToken
    {
        let settings = context.settings?.stepfun

        // 1. Manual mode: use the token directly from settings
        if settings?.cookieSource == .manual {
            let manualToken = settings?.manualToken ?? ""
            guard !manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StepFunUsageError.missingToken
            }
            return ResolvedToken(
                token: StepFunTokenNormalizer.normalize(manualToken),
                source: .manual)
        }

        // 2. Cached token from previous login
        if allowCached, let cached = CookieHeaderCache.load(provider: .stepfun) {
            return ResolvedToken(
                token: StepFunTokenNormalizer.normalize(cached.cookieHeader),
                source: .cached)
        }

        // 3. Username + password from Settings UI → perform full login flow
        //    (register device → sign in by password → get Oasis-Token)
        if let settings, !settings.username.isEmpty, !settings.password.isEmpty {
            let token = try await StepFunUsageFetcher.login(
                username: settings.username,
                password: settings.password)
            CookieHeaderCache.store(provider: .stepfun, cookieHeader: token, sourceLabel: "login")
            return ResolvedToken(token: token, source: .settingsLogin)
        }

        // 4. Direct token from env var
        if let token = StepFunSettingsReader.token(environment: context.env) {
            return ResolvedToken(token: token, source: .environmentToken)
        }

        // 5. Username + password from env vars → perform full login flow
        if let username = StepFunSettingsReader.username(environment: context.env),
           let password = StepFunSettingsReader.password(environment: context.env)
        {
            let token = try await StepFunUsageFetcher.login(username: username, password: password)
            CookieHeaderCache.store(provider: .stepfun, cookieHeader: token, sourceLabel: "login")
            return ResolvedToken(token: token, source: .environmentLogin)
        }

        throw StepFunUsageError.missingCredentials
    }

    private func recoverFromAuthenticationFailure(
        context: ProviderFetchContext,
        originalError: Error) async throws -> ProviderFetchResult
    {
        let resolved = try await Self.resolveToken(context: context, allowCached: true)
        do {
            let refreshed = try await StepFunUsageFetcher.refreshToken(token: resolved.token)
            await Self.persistRecoveredToken(refreshed, source: resolved.source, context: context)
            let usage = try await StepFunUsageFetcher.fetchUsage(token: refreshed)
            return self.makeResult(
                usage: usage.toUsageSnapshot(),
                sourceLabel: "web")
        } catch {
            if let loginToken = try await Self.loginTokenIfAvailable(context: context) {
                let usage = try await StepFunUsageFetcher.fetchUsage(token: loginToken)
                return self.makeResult(
                    usage: usage.toUsageSnapshot(),
                    sourceLabel: "web")
            }
            throw Self.actionableAuthenticationError(for: resolved.source, originalError: originalError)
        }
    }

    private static func loginTokenIfAvailable(context: ProviderFetchContext) async throws -> String? {
        let settings = context.settings?.stepfun
        if settings?.cookieSource != .manual,
           let settings,
           !settings.username.isEmpty,
           !settings.password.isEmpty
        {
            CookieHeaderCache.clear(provider: .stepfun)
            let token = try await StepFunUsageFetcher.login(
                username: settings.username,
                password: settings.password)
            CookieHeaderCache.store(provider: .stepfun, cookieHeader: token, sourceLabel: "login")
            return token
        }

        if let username = StepFunSettingsReader.username(environment: context.env),
           let password = StepFunSettingsReader.password(environment: context.env)
        {
            CookieHeaderCache.clear(provider: .stepfun)
            let token = try await StepFunUsageFetcher.login(username: username, password: password)
            CookieHeaderCache.store(provider: .stepfun, cookieHeader: token, sourceLabel: "login")
            return token
        }

        return nil
    }

    private static func persistRecoveredToken(
        _ token: String,
        source: TokenSource,
        context: ProviderFetchContext) async
    {
        switch source {
        case .cached, .settingsLogin, .environmentLogin:
            CookieHeaderCache.store(provider: .stepfun, cookieHeader: token, sourceLabel: "refresh")
        case .manual, .environmentToken:
            guard let accountID = context.selectedTokenAccountID,
                  let updater = context.tokenAccountTokenUpdater
            else { return }
            await updater(.stepfun, accountID, token)
        }
    }

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard case let StepFunUsageError.apiError(message) = error else {
            return false
        }
        let lower = message.lowercased()
        return lower.contains("401") ||
            lower.contains("unauthorized") ||
            lower.contains("token") ||
            lower.contains("auth")
    }

    private static func actionableAuthenticationError(
        for source: TokenSource,
        originalError: Error) -> StepFunUsageError
    {
        let suffix = switch source {
        case .manual:
            "Refresh the Oasis-Token, or switch StepFun to auto auth with username/password."
        case .environmentToken:
            "Refresh STEPFUN_TOKEN, or configure STEPFUN_USERNAME and STEPFUN_PASSWORD."
        case .cached, .settingsLogin, .environmentLogin:
            "Refresh the StepFun credentials and try again."
        }
        return .apiError("\(Self.authenticationFailureMessage(originalError)). \(suffix)")
    }

    private static func authenticationFailureMessage(_ error: Error) -> String {
        if case let StepFunUsageError.apiError(message) = error {
            return message
        }
        return error.localizedDescription
    }
}

// MARK: - Token Normalizer

public enum StepFunTokenNormalizer {
    /// Normalize a StepFun token value — extracts the Oasis-Token from a cookie header
    /// or returns the raw token value if it's not a cookie header.
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // If it looks like a cookie header, extract Oasis-Token
        if trimmed.contains("Oasis-Token=") {
            let parts = trimmed.components(separatedBy: "Oasis-Token=")
            if parts.count > 1 {
                let afterToken = parts[1]
                return afterToken.components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces) ?? afterToken
            }
        }

        return trimmed
    }
}
