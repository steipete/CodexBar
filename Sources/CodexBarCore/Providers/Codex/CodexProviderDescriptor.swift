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
                browserCookieOrder: [.chrome, .dia, .safari, .firefox],
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
                if context.settings?.codex?.cookieSource == .manual {
                    return [web, cli]
                }
                return [oauth, cli]
            }
        }
    }

    private static func noDataMessage() -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let base = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        } ?? "\(home)/.codex"
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

enum CodexUsageResponseMapper {
    static func makeUsageSnapshot(
        _ response: CodexUsageResponse,
        accountEmail: String?,
        plan: String?) -> UsageSnapshot
    {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: accountEmail,
            accountOrganization: nil,
            loginMethod: plan)

        return UsageSnapshot(
            primary: self.makeWindow(response.rateLimit?.primaryWindow)
                ?? RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: self.makeWindow(response.rateLimit?.secondaryWindow),
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)
    }

    static func makeCreditsSnapshot(_ credits: CodexUsageResponse.CreditDetails?) -> CreditsSnapshot? {
        guard let credits, let balance = credits.balance else { return nil }
        return CreditsSnapshot(remaining: balance, events: [], updatedAt: Date())
    }

    static func makeWindow(_ window: CodexUsageResponse.WindowSnapshot?) -> RateWindow? {
        guard let window else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(window.resetAt))
        let resetDescription = UsageFormatter.resetDescription(from: resetDate)
        return RateWindow(
            usedPercent: Double(window.usedPercent),
            windowMinutes: window.limitWindowSeconds / 60,
            resetsAt: resetDate,
            resetDescription: resetDescription)
    }
}

struct CodexCLIUsageStrategy: ProviderFetchStrategy {
    let id: String = "codex.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let keepAlive = context.settings?.debugKeepCLISessionsAlive ?? false
        let usage = try await context.fetcher.loadLatestUsage(keepCLISessionsAlive: keepAlive)
        let credits = await context.includeCredits
            ? (try? context.fetcher.loadLatestCredits(keepCLISessionsAlive: keepAlive))
            : nil
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
        if let rawSource = context.settings?.codex?.oauthCredentialSource {
            return (try? CodexOAuthCredentialsStore.load(rawSource: rawSource)) != nil
        }
        return (try? CodexOAuthCredentialsStore.load()) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let rawSource = context.settings?.codex?.oauthCredentialSource
        var credentials = try self.loadCredentials(rawSource: rawSource)

        if credentials.needsRefresh, !credentials.refreshToken.isEmpty {
            credentials = try await CodexTokenRefresher.refresh(credentials)
            try self.saveCredentials(credentials, rawSource: rawSource)
        }

        let usage = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: credentials.accessToken,
            accountId: credentials.accountId)

        return self.makeResult(
            usage: CodexUsageResponseMapper.makeUsageSnapshot(
                usage,
                accountEmail: Self.resolveAccountEmail(from: credentials),
                plan: Self.resolvePlan(response: usage, credentials: credentials)),
            credits: CodexUsageResponseMapper.makeCreditsSnapshot(usage.credits),
            sourceLabel: "oauth")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        return true
    }

    private static func resolveAccountEmail(from credentials: CodexOAuthCredentials) -> String? {
        guard let idToken = credentials.idToken,
              let payload = UsageFetcher.parseJWT(idToken)
        else {
            return nil
        }

        let profileDict = payload["https://api.openai.com/profile"] as? [String: Any]
        let email = (payload["email"] as? String) ?? (profileDict?["email"] as? String)
        return email?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolvePlan(response: CodexUsageResponse, credentials: CodexOAuthCredentials) -> String? {
        if let plan = response.planType?.rawValue, !plan.isEmpty { return plan }
        guard let idToken = credentials.idToken,
              let payload = UsageFetcher.parseJWT(idToken)
        else {
            return nil
        }
        let authDict = payload["https://api.openai.com/auth"] as? [String: Any]
        let plan = (authDict?["chatgpt_plan_type"] as? String) ?? (payload["chatgpt_plan_type"] as? String)
        return plan?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadCredentials(rawSource: String?) throws -> CodexOAuthCredentials {
        if let rawSource, !rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try CodexOAuthCredentialsStore.load(rawSource: rawSource)
        }
        return try CodexOAuthCredentialsStore.load()
    }

    private func saveCredentials(_ credentials: CodexOAuthCredentials, rawSource: String?) throws {
        if let rawSource {
            if CodexOAuthCredentialsStore.authFileURL(forRawSource: rawSource) != nil {
                try CodexOAuthCredentialsStore.save(credentials, rawSource: rawSource)
            }
            return
        }
        try CodexOAuthCredentialsStore.save(credentials)
    }
}

#if DEBUG
extension CodexOAuthFetchStrategy {
    static func _mapUsageForTesting(_ data: Data, credentials: CodexOAuthCredentials) throws -> UsageSnapshot {
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        return CodexUsageResponseMapper.makeUsageSnapshot(
            usage,
            accountEmail: Self.resolveAccountEmail(from: credentials),
            plan: Self.resolvePlan(response: usage, credentials: credentials))
    }
}
#endif
