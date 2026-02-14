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
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
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

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        (try? CodexOAuthCredentialsStore.load()) != nil
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        var credentials = try CodexOAuthCredentialsStore.load()

        if credentials.needsRefresh, !credentials.refreshToken.isEmpty {
            credentials = try await CodexTokenRefresher.refresh(credentials)
            try CodexOAuthCredentialsStore.save(credentials)
        }

        let usage = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: credentials.accessToken,
            accountId: credentials.accountId)

        return self.makeResult(
            usage: Self.mapUsage(usage, credentials: credentials),
            credits: Self.mapCredits(usage.credits),
            sourceLabel: "oauth")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        return true
    }

    private static func mapUsage(_ response: CodexUsageResponse, credentials: CodexOAuthCredentials) -> UsageSnapshot {
        let primary = Self.makeWindow(response.rateLimit?.primaryWindow)
        let secondary = Self.makeWindow(response.rateLimit?.secondaryWindow)

        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: Self.resolveAccountEmail(from: credentials),
            accountOrganization: nil,
            loginMethod: Self.resolvePlan(response: response, credentials: credentials))

        return UsageSnapshot(
            primary: primary ?? RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: secondary,
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)
    }

    private static func mapCredits(_ credits: CodexUsageResponse.CreditDetails?) -> CreditsSnapshot? {
        guard let credits, let balance = credits.balance else { return nil }
        return CreditsSnapshot(remaining: balance, events: [], updatedAt: Date())
    }

    private static func makeWindow(_ window: CodexUsageResponse.WindowSnapshot?) -> RateWindow? {
        guard let window else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(window.resetAt))
        let resetDescription = UsageFormatter.resetDescription(from: resetDate)
        return RateWindow(
            usedPercent: Double(window.usedPercent),
            windowMinutes: window.limitWindowSeconds / 60,
            resetsAt: resetDate,
            resetDescription: resetDescription)
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
}

#if DEBUG
extension CodexOAuthFetchStrategy {
    static func _mapUsageForTesting(_ data: Data, credentials: CodexOAuthCredentials) throws -> UsageSnapshot {
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        return Self.mapUsage(usage, credentials: credentials)
    }
}
#endif
