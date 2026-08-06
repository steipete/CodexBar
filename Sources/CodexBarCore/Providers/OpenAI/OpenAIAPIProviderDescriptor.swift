import Foundation

public enum OpenAIAPIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey,
        additionalProjections: [.workspaceID(OpenAIAPISettingsReader.projectIDEnvironmentKey)],
        resolve: OpenAIAPISettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple OpenAI API keys.",
            placeholder: "sk-admin-...",
            injection: .environment(key: OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil,
            environmentKeysToScrub: [OpenAIAPISettingsReader.projectIDEnvironmentKey]))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .openai,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 1),
            metadata: ProviderMetadata(
                id: .openai,
                displayName: "OpenAI",
                sessionLabel: "Spend",
                weeklyLabel: "Requests",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenAI usage",
                cliName: "openai",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://platform.openai.com/usage",
                statusPageURL: "https://status.openai.com"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .openai),
                iconResourceName: "ProviderIcon-codex",
                color: ProviderColor(red: 0.06, green: 0.51, blue: 0.43),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0x808080),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(red: 15 / 255, green: 130 / 255, blue: 110 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "OpenAI usage needs an Admin API key for organization usage." },
                menuHintLines: [.literal("Reported by OpenAI Admin API organization usage.")],
                showsCostMenuSection: false),
            presentation: ProviderUsagePresentation(
                costPresenter: { snapshot in
                    let style: ProviderCostMenuCardStyle = (snapshot.providerCost?.limit ?? 1) <= 0
                        ? .apiSpend
                        : .generic
                    return ProviderCostPresentation(menuCardStyle: style)
                },
                menuCard: ProviderMenuCardPresentation(
                    usageNotesResolver: { context in
                        context.snapshot?.openAIAPIUsage.map(ProviderUsageNotesResolution.openAIAPI) ?? .unhandled
                    },
                    costVisibilityResolver: { $0.snapshot?.openAIAPIUsage == nil },
                    usesProviderCostHistoryAsPrimaryDashboard: true,
                    primaryCostHistoryResolver: { snapshot, tokenSnapshot in
                        if let projected = snapshot?.openAIAPIUsage?.toCostUsageTokenSnapshot() {
                            return projected
                        }
                        return snapshot == nil ? tokenSnapshot : nil
                    })),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "openai",
                aliases: ["openai-api"],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        #if canImport(JavaScriptCore)
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                let swift = OpenAIAPIBalanceFetchStrategy()
                guard ProviderPluginPrototype.isEnabled(environment: context.env) else { return [swift] }
                return [
                    ScriptFetchStrategy(
                        id: "openai.js",
                        provider: .openai,
                        bundledPlugin: "openai",
                        secretKey: OpenAIAPISettingsReader.apiKeyEnvironmentKey,
                        resolveValues: { context in
                            guard let credential = OpenAIAPIUsageCredential(environment: context.env)
                            else { return nil }
                            var settings: [String: String] = [:]
                            if let projectID = credential.projectID {
                                settings[OpenAIAPISettingsReader.projectIDEnvironmentKey] = projectID
                            }
                            settings["OPENAI_HISTORY_DAYS"] = String(context.costUsageHistoryDays)
                            settings["OPENAI_ALLOW_BALANCE_FALLBACK"] =
                                credential.allowsLegacyBalanceFallback ? "1" : "0"
                            return ScriptFetchStrategy.Values(
                                settings: settings,
                                secrets: [OpenAIAPISettingsReader.apiKeyEnvironmentKey: credential.apiKey])
                        }),
                    swift,
                ]
            }))
        #else
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [OpenAIAPIBalanceFetchStrategy()] }))
        #endif
    }
}

struct OpenAIAPIBalanceFetchStrategy: ProviderFetchStrategy {
    let id: String = "openai.api.balance"
    let kind: ProviderFetchKind = .apiToken
    let usageFetcher: @Sendable (OpenAIAPIUsageCredential, Int) async throws -> OpenAIAPIUsageSnapshot
    let balanceFetcher: @Sendable (String) async throws -> OpenAIAPICreditBalanceSnapshot

    init(
        usageFetcher: @escaping @Sendable (OpenAIAPIUsageCredential, Int) async throws -> OpenAIAPIUsageSnapshot =
            OpenAIAPIBalanceFetchStrategy.fetchUsage(credential:days:),
        balanceFetcher: @escaping @Sendable (String) async throws -> OpenAIAPICreditBalanceSnapshot = { apiKey in
            try await OpenAIAPICreditBalanceFetcher.fetchBalance(apiKey: apiKey)
        })
    {
        self.usageFetcher = usageFetcher
        self.balanceFetcher = balanceFetcher
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        OpenAIAPIUsageCredential(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let credential = OpenAIAPIUsageCredential(environment: context.env) else {
            throw OpenAIAPISettingsError.missingToken
        }

        do {
            let usage = try await self.usageFetcher(credential, context.costUsageHistoryDays)
            return self.makeResult(
                usage: usage.toUsageSnapshot(),
                sourceLabel: credential.sourceLabel)
        } catch {
            let usageError = error
            if !credential.allowsLegacyBalanceFallback {
                throw usageError
            }
            // Preserve the older balance-only path for unscoped keys and Admin API outages.
            do {
                let balance = try await self.balanceFetcher(credential.apiKey)
                return self.makeResult(
                    usage: balance.toUsageSnapshot(),
                    sourceLabel: "billing-api")
            } catch {
                if (usageError as? OpenAIAPIUsageError)?.isCredentialRejected != true {
                    throw usageError
                }
                throw error
            }
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func fetchUsage(
        credential: OpenAIAPIUsageCredential,
        days: Int) async throws -> OpenAIAPIUsageSnapshot
    {
        try await OpenAIAPIUsageFetcher.fetchUsage(
            apiKey: credential.apiKey,
            projectID: credential.projectID,
            historyDays: days)
    }
}

struct OpenAIAPIUsageCredential: Equatable {
    let apiKey: String
    let projectID: String?
    let usesAdminKey: Bool

    init?(environment: [String: String]) {
        if let adminKey = OpenAIAPISettingsReader.adminAPIKey(environment: environment) {
            self.apiKey = adminKey
            self.usesAdminKey = true
        } else if let apiKey = OpenAIAPISettingsReader.apiKey(environment: environment) {
            self.apiKey = apiKey
            self.usesAdminKey = false
        } else {
            return nil
        }
        self.projectID = OpenAIAPISettingsReader.projectID(environment: environment)
    }

    var sourceLabel: String {
        self.projectID == nil ? "admin-api" : "admin-api:project"
    }

    var allowsLegacyBalanceFallback: Bool {
        self.projectID == nil || !self.usesAdminKey
    }
}
