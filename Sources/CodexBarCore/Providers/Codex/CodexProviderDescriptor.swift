import Foundation

public enum CodexProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .codex,
            metadata: ProviderMetadata(
                id: .codex,
                displayName: "Codex",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Credits unavailable; keep Codex running to refresh.",
                toggleTitle: "Show Codex usage",
                cliName: "codex",
                defaultEnabled: true,
                isPrimaryProvider: true,
                usesAccountFallback: true,
                browserCookieOrder: ProviderBrowserCookieDefaults.codexCookieImportOrder
                    ?? ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://chatgpt.com/codex/settings/usage",
                changelogURL: "https://github.com/openai/codex/releases",
                statusPageURL: "https://status.openai.com/"),
            branding: ProviderBranding(
                iconStyle: .codex,
                iconResourceName: "ProviderIcon-codex",
                color: ProviderColor(red: 73 / 255, green: 163 / 255, blue: 176 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: self.noDataMessage),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .cli, .oauth],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "codex",
                versionDetector: { _ in ProviderVersionDetector.codexVersion() }))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        let cli = CodexCLIUsageStrategy()
        let oauth = CodexOAuthFetchStrategy()
        let web = CodexWebDashboardStrategy()

        switch context.runtime {
        case .cli:
            switch context.sourceMode {
            case .oauth:
                return [oauth]
            case .web:
                return [web]
            case .cli:
                return [cli]
            case .api:
                return []
            case .auto:
                return [oauth, cli]
            }
        case .app:
            switch context.sourceMode {
            case .oauth:
                return [oauth]
            case .cli:
                return [cli]
            case .web:
                return [web]
            case .api:
                return []
            case .auto:
                return [oauth, cli]
            }
        }
    }

    private static func noDataMessage() -> String {
        self.noDataMessage(env: ProcessInfo.processInfo.environment)
    }

    private static func noDataMessage(env: [String: String], fileManager: FileManager = .default) -> String {
        let base = CodexHomeScope.ambientHomeURL(env: env, fileManager: fileManager).path
        let sessions = "\(base)/sessions"
        let archived = "\(base)/archived_sessions"
        return "No Codex sessions found in \(sessions) or \(archived)."
    }

    public static func resolveUsageStrategy(
        selectedDataSource: CodexUsageDataSource,
        hasOAuthCredentials: Bool) -> CodexUsageStrategy
    {
        if selectedDataSource == .auto {
            if hasOAuthCredentials {
                return CodexUsageStrategy(dataSource: .oauth)
            }
            return CodexUsageStrategy(dataSource: .cli)
        }
        return CodexUsageStrategy(dataSource: selectedDataSource)
    }
}

public struct CodexUsageStrategy: Equatable, Sendable {
    public let dataSource: CodexUsageDataSource
}

struct CodexCLIUsageStrategy: ProviderFetchStrategy {
    let id: String = "codex.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolvedBinary(env: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await context.fetcher.loadLatestCLIAccountSnapshot()
        guard let usage = snapshot.usage else {
            guard context.includeCredits, let credits = snapshot.credits else {
                throw UsageError.noRateLimitsFound
            }
            // Credits refresh can succeed even when RPC omits rate-limit windows.
            return self.makeResult(
                usage: UsageSnapshot(
                    primary: nil,
                    secondary: nil,
                    updatedAt: credits.updatedAt,
                    identity: snapshot.identity),
                credits: credits,
                sourceLabel: "codex-cli")
        }
        let credits = context.includeCredits ? snapshot.credits : nil
        return self.makeResult(
            usage: usage,
            credits: credits,
            sourceLabel: "codex-cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    static func resolvedBinary(
        env: [String: String],
        loginPATH: [String]? = LoginShellPathCache.shared.current,
        commandV: (String, String?, TimeInterval, FileManager) -> String? = ShellCommandLocator.commandV,
        aliasResolver: (String, String?, TimeInterval, FileManager, String) -> String? = ShellCommandLocator
            .resolveAlias,
        fileManager: FileManager = .default,
        home: String = NSHomeDirectory()) -> String?
    {
        BinaryLocator.resolveCodexBinary(
            env: env,
            loginPATH: loginPATH,
            commandV: commandV,
            aliasResolver: aliasResolver,
            fileManager: fileManager,
            home: home)
    }
}

struct CodexOAuthFetchStrategy: ProviderFetchStrategy {
    let id: String = "codex.oauth"
    let kind: ProviderFetchKind = .oauth

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        (try? CodexOAuthCredentialsStore.load(env: context.env)) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        var credentials = try CodexOAuthCredentialsStore.load(env: context.env)

        if credentials.needsRefresh, !credentials.refreshToken.isEmpty {
            credentials = try await CodexTokenRefresher.refresh(credentials)
            try CodexOAuthCredentialsStore.save(credentials, env: context.env)
        }

        let usage = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: credentials.accessToken,
            accountId: credentials.accountId,
            env: context.env)
        let resetCredits = try await Self.fetchResetCreditsIfRequested(
            context: context,
            credentials: credentials)
        let updatedAt = Date()
        let oauthResult = try Self.makeResult(
            usageResponse: usage,
            resetCredits: resetCredits,
            credentials: credentials,
            updatedAt: updatedAt,
            allowEmptyUsageForResetCreditEnrichment: Self.defersResetCreditFetchToApp(context))
        return try await Self.replacingWithCLIMonthlyLimitIfAvailable(oauthResult, context: context)
    }

    private static func shouldFetchResetCredits(_ context: ProviderFetchContext) -> Bool {
        guard case .cli = context.runtime else { return false }
        return context.includeCredits
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        // Auto mode may launch the CLI as the next strategy. Keep that fallback
        // limited to OAuth states the CLI can actually repair, otherwise
        // transient API or decode failures can spawn `codex app-server`
        // repeatedly instead of surfacing the original OAuth failure.
        if let fetchError = error as? CodexOAuthFetchError {
            switch fetchError {
            case .unauthorized:
                return true
            case .invalidResponse, .serverError, .networkError:
                return false
            }
        }
        if let credentialsError = error as? CodexOAuthCredentialsError {
            switch credentialsError {
            case .notFound, .missingTokens:
                return true
            case .decodeFailed:
                return false
            }
        }
        switch error as? CodexTokenRefresher.RefreshError {
        case .expired, .revoked, .reused:
            return true
        case .networkError, .invalidResponse, .none:
            return false
        }
    }

    private static func mapCredits(
        response: CodexUsageResponse,
        updatedAt: Date) -> CreditsSnapshot?
    {
        let balance = response.credits?.balance
        let creditLimit = (response.individualLimit ?? response.rateLimit?.individualLimit)?
            .codexCreditLimitSnapshot(updatedAt: updatedAt)
        guard balance != nil || creditLimit != nil else { return nil }
        return CreditsSnapshot(
            remaining: balance ?? 0,
            events: [],
            updatedAt: updatedAt,
            codexCreditLimit: creditLimit)
    }

    private static func makeResult(
        usageResponse: CodexUsageResponse,
        resetCredits: CodexRateLimitResetCreditsSnapshot? = nil,
        credentials: CodexOAuthCredentials,
        updatedAt: Date,
        allowEmptyUsageForResetCreditEnrichment: Bool = false) throws -> ProviderFetchResult
    {
        let credits = Self.mapCredits(response: usageResponse, updatedAt: updatedAt)
        let reconciled = CodexReconciledState.fromOAuth(
            response: usageResponse,
            credentials: credentials,
            updatedAt: updatedAt)

        if let reconciled {
            let dataConfidence: UsageDataConfidence = usageResponse.rateLimit?.hasWindowDecodeFailure == true
                || usageResponse.additionalRateLimitsDecodeFailed
                ? .unknown
                : .exact
            return CodexOAuthFetchStrategy().makeResult(
                usage: reconciled.toUsageSnapshot()
                    .withCodexResetCredits(resetCredits)
                    .withDataConfidence(dataConfidence),
                credits: credits,
                sourceLabel: "oauth")
        }

        guard credits != nil
            || (resetCredits?.availableInventory(at: updatedAt).count ?? 0) > 0
            || allowEmptyUsageForResetCreditEnrichment
        else {
            throw UsageError.noRateLimitsFound
        }

        // Credit balances and manual resets remain useful when OAuth omits
        // rate-limit windows. Keep the partial result instead of discarding it.
        return CodexOAuthFetchStrategy().makeResult(
            usage: UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                codexResetCredits: resetCredits,
                updatedAt: updatedAt,
                identity: CodexReconciledState.oauthIdentity(
                    response: usageResponse,
                    credentials: credentials)),
            credits: credits,
            sourceLabel: "oauth")
    }

    private static func replacingWithCLIMonthlyLimitIfAvailable(
        _ oauthResult: ProviderFetchResult,
        context: ProviderFetchContext,
        cliStrategy: any ProviderFetchStrategy = CodexCLIUsageStrategy()) async throws -> ProviderFetchResult
    {
        guard context.sourceMode == .auto,
              context.includeCredits,
              self.shouldTryCLIForMonthlyLimit(oauthResult)
        else { return oauthResult }
        guard await cliStrategy.isAvailable(context) else { return oauthResult }
        let cliResult: ProviderFetchResult
        do {
            cliResult = try await cliStrategy.fetch(context)
        } catch {
            if error is CancellationError { throw error }
            return oauthResult
        }
        guard let cliLimit = cliResult.credits?.codexCreditLimit,
              self.identitiesAreCompatible(oauth: oauthResult.usage.identity, cli: cliResult.usage.identity),
              let oauthCredits = oauthResult.credits
        else { return oauthResult }
        return ProviderFetchResult(
            usage: oauthResult.usage,
            credits: CreditsSnapshot(
                remaining: oauthCredits.remaining,
                events: oauthCredits.events,
                updatedAt: oauthCredits.updatedAt,
                codexCreditLimit: cliLimit),
            dashboard: oauthResult.dashboard,
            sourceLabel: oauthResult.sourceLabel,
            strategyID: oauthResult.strategyID,
            strategyKind: oauthResult.strategyKind)
    }

    private static func fetchResetCreditsIfRequested(
        context: ProviderFetchContext,
        credentials: CodexOAuthCredentials) async throws -> CodexRateLimitResetCreditsSnapshot?
    {
        try await self.fetchResetCreditsIfRequested(
            context: context,
            credentials: credentials,
            fetcher: { credentials in
                try await CodexOAuthUsageFetcher.fetchRateLimitResetCredits(
                    accessToken: credentials.accessToken,
                    accountId: credentials.accountId,
                    env: context.env)
            })
    }

    private static func defersResetCreditFetchToApp(_ context: ProviderFetchContext) -> Bool {
        if case .app = context.runtime { return true }
        return false
    }

    private static func fetchResetCreditsIfRequested(
        context: ProviderFetchContext,
        credentials: CodexOAuthCredentials,
        fetcher: @escaping @Sendable (CodexOAuthCredentials) async throws
            -> CodexRateLimitResetCreditsSnapshot) async throws -> CodexRateLimitResetCreditsSnapshot?
    {
        guard self.shouldFetchResetCredits(context) else { return nil }
        // The app enriches the winning outcome once in UsageStore. One-shot CLI callers do not
        // pass through that app layer, so only their explicit credits flag reaches this request.
        do {
            return try await fetcher(credentials)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return nil
        }
    }

    private static func identitiesAreCompatible(
        oauth: ProviderIdentitySnapshot?,
        cli: ProviderIdentitySnapshot?) -> Bool
    {
        guard let cliEmail = self.normalizedEmail(cli?.accountEmail),
              let oauthEmail = self.normalizedEmail(oauth?.accountEmail)
        else { return false }
        return cliEmail == oauthEmail
    }

    private static func normalizedEmail(_ email: String?) -> String? {
        guard let normalized = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty
        else { return nil }
        return normalized
    }

    private static func shouldTryCLIForMonthlyLimit(_ result: ProviderFetchResult) -> Bool {
        guard let credits = result.credits else { return false }
        return credits.remaining == 0
            && credits.codexCreditLimit == nil
            && (result.usage.codexResetCredits?.availableInventory(at: result.usage.updatedAt).count ?? 0) == 0
    }
}

#if DEBUG
extension CodexOAuthFetchStrategy {
    static func _fetchResetCreditsForTesting(
        context: ProviderFetchContext,
        credentials: CodexOAuthCredentials,
        fetcher: @escaping @Sendable (CodexOAuthCredentials) async throws
            -> CodexRateLimitResetCreditsSnapshot) async throws -> CodexRateLimitResetCreditsSnapshot?
    {
        try await self.fetchResetCreditsIfRequested(
            context: context,
            credentials: credentials,
            fetcher: fetcher)
    }

    static func _shouldFetchResetCreditsForTesting(_ context: ProviderFetchContext) -> Bool {
        self.shouldFetchResetCredits(context)
    }
}
#endif

#if DEBUG
extension CodexOAuthFetchStrategy {
    static func _mapUsageForTesting(_ data: Data, credentials: CodexOAuthCredentials) throws -> UsageSnapshot? {
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        return CodexReconciledState.fromOAuth(response: usage, credentials: credentials)?.toUsageSnapshot()
    }

    static func _mapResultForTesting(
        _ data: Data,
        credentials: CodexOAuthCredentials,
        resetCredits: CodexRateLimitResetCreditsSnapshot? = nil,
        sourceMode: ProviderSourceMode = .oauth,
        allowEmptyUsageForResetCreditEnrichment: Bool = false) throws -> ProviderFetchResult
    {
        let usageResponse = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        _ = sourceMode
        return try Self.makeResult(
            usageResponse: usageResponse,
            resetCredits: resetCredits,
            credentials: credentials,
            updatedAt: Date(),
            allowEmptyUsageForResetCreditEnrichment: allowEmptyUsageForResetCreditEnrichment)
    }

    static func _replaceWithCLIMonthlyLimitForTesting(
        oauthResult: ProviderFetchResult,
        context: ProviderFetchContext,
        cliStrategy: any ProviderFetchStrategy) async throws -> ProviderFetchResult
    {
        try await self.replacingWithCLIMonthlyLimitIfAvailable(
            oauthResult,
            context: context,
            cliStrategy: cliStrategy)
    }

    static func _shouldTryCLIForMonthlyLimitForTesting(_ result: ProviderFetchResult) -> Bool {
        self.shouldTryCLIForMonthlyLimit(result)
    }
}

extension CodexProviderDescriptor {
    static func _noDataMessageForTesting(env: [String: String]) -> String {
        self.noDataMessage(env: env)
    }
}
#endif
