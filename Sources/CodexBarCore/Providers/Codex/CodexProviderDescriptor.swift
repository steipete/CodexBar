import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum CodexProviderDescriptor {
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
                return [web, cli]
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

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await context.fetcher.loadLatestCLIAccountSnapshot()
        guard let usage = snapshot.usage else { throw UsageError.noRateLimitsFound }
        let credits = context.includeCredits ? snapshot.credits : nil
        return self.makeResult(
            usage: usage,
            credits: credits,
            sourceLabel: "codex-cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
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
        let updatedAt = Date()
        return try Self.makeResult(
            usageResponse: usage,
            credentials: credentials,
            updatedAt: updatedAt,
            sourceMode: context.sourceMode)
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

    private static func mapCredits(_ credits: CodexUsageResponse.CreditDetails?) -> CreditsSnapshot? {
        guard let credits, let balance = credits.balance else { return nil }
        return CreditsSnapshot(remaining: balance, events: [], updatedAt: Date())
    }

    private static func makeResult(
        usageResponse: CodexUsageResponse,
        credentials: CodexOAuthCredentials,
        updatedAt: Date,
        sourceMode: ProviderSourceMode) throws -> ProviderFetchResult
    {
        let credits = Self.mapCredits(usageResponse.credits)
        let reconciled = CodexReconciledState.fromOAuth(
            response: usageResponse,
            credentials: credentials,
            updatedAt: updatedAt)

        if let reconciled {
            return CodexOAuthFetchStrategy().makeResult(
                usage: reconciled.toUsageSnapshot(),
                credits: credits,
                sourceLabel: "oauth")
        }

        guard let credits else {
            throw UsageError.noRateLimitsFound
        }

        // Credits can still be useful when the OAuth API omits or partially
        // fails to decode rate-limit windows. Returning the partial OAuth result
        // prevents auto mode from escalating a usable response into CLI fallback.
        return CodexOAuthFetchStrategy().makeResult(
            usage: UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                updatedAt: updatedAt,
                identity: CodexReconciledState.oauthIdentity(
                    response: usageResponse,
                    credentials: credentials)),
            credits: credits,
            sourceLabel: "oauth")
    }
}

#if DEBUG
extension CodexOAuthFetchStrategy {
    static func _mapUsageForTesting(_ data: Data, credentials: CodexOAuthCredentials) throws -> UsageSnapshot? {
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        return CodexReconciledState.fromOAuth(response: usage, credentials: credentials)?.toUsageSnapshot()
    }

    static func _mapResultForTesting(
        _ data: Data,
        credentials: CodexOAuthCredentials,
        sourceMode: ProviderSourceMode = .oauth) throws -> ProviderFetchResult
    {
        let usageResponse = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        return try Self.makeResult(
            usageResponse: usageResponse,
            credentials: credentials,
            updatedAt: Date(),
            sourceMode: sourceMode)
    }
}

extension CodexProviderDescriptor {
    static func _noDataMessageForTesting(env: [String: String]) -> String {
        self.noDataMessage(env: env)
    }
}
#endif
