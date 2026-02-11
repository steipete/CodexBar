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
                sessionLabel: L10n.tr("provider.codex.metadata.session_label", fallback: "Session"),
                weeklyLabel: L10n.tr("provider.codex.metadata.weekly_label", fallback: "Weekly"),
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: L10n.tr(
                    "provider.codex.metadata.credits_hint",
                    fallback: "Credits unavailable; keep Codex running to refresh."),
                toggleTitle: L10n.tr("provider.codex.metadata.toggle_title", fallback: "Show Codex usage"),
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
            case .api:
                return [web, cli]
            case .web:
                return [web]
            case .cli:
                return [cli]
            case .auto:
                return [web, cli]
            }
        case .app:
            switch context.sourceMode {
            case .oauth:
                return [oauth]
            case .api:
                return [oauth, cli]
            case .cli:
                return [cli]
            case .web:
                return [web]
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
        let format = L10n.tr(
            "provider.codex.no_data_message",
            fallback: "No Codex sessions found in %@ or %@.")
        return String(format: format, locale: .current, sessions, archived)
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
            usage: CodexUsageSnapshotMapper.usageSnapshot(
                from: usage,
                accountEmail: Self.resolveAccountEmail(from: credentials),
                fallbackLoginMethod: Self.resolvePlan(response: usage, credentials: credentials)),
            credits: CodexUsageSnapshotMapper.creditsSnapshot(from: usage.credits),
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
}

struct CodexCLIProxyFetchStrategy: ProviderFetchStrategy {
    let id: String = "codex.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if context.sourceMode == .api { return true }
        return CodexCLIProxySettings.resolve(
            providerSettings: context.settings?.codex,
            environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let settings = CodexCLIProxySettings.resolve(
            providerSettings: context.settings?.codex,
            environment: context.env)
        else {
            throw CodexCLIProxyError.missingManagementKey
        }

        let client = CodexCLIProxyManagementClient(settings: settings)
        let auth = try await client.resolveCodexAuth()
        let usage = try await client.fetchCodexUsage(auth: auth)

        return self.makeResult(
            usage: CodexUsageSnapshotMapper.usageSnapshot(
                from: usage,
                accountEmail: auth.email,
                fallbackLoginMethod: auth.planType),
            credits: CodexUsageSnapshotMapper.creditsSnapshot(from: usage.credits),
            sourceLabel: "cliproxy-api")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}

#if DEBUG
extension CodexOAuthFetchStrategy {
    static func _mapUsageForTesting(_ data: Data, credentials: CodexOAuthCredentials) throws -> UsageSnapshot {
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        return CodexUsageSnapshotMapper.usageSnapshot(
            from: usage,
            accountEmail: Self.resolveAccountEmail(from: credentials),
            fallbackLoginMethod: Self.resolvePlan(response: usage, credentials: credentials))
    }
}
#endif
