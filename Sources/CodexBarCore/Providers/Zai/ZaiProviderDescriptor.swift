import Foundation

public enum ZaiProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .zai,
            settingsSection: .init(ZaiProviderSettingsKey.self),
            metadata: ProviderMetadata(
                id: .zai,
                displayName: "z.ai / GLM",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show z.ai / GLM usage",
                cliName: "zai",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: ZaiAPIRegion.global.dashboardURL.absoluteString,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .zai),
                iconResourceName: "ProviderIcon-zai",
                color: ProviderColor(red: 232 / 255, green: 90 / 255, blue: 106 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x126EF6),
                    ProviderColor(hex: 0x2D2D2D),
                    ProviderColor(hex: 0xDFE2E7),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "z.ai cost summary is not supported." }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "zai",
                aliases: ["z.ai"],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        let loadUsage: APITokenFetchStrategy.UsageLoader = { apiKey, context in
            let settings = context.settings?.zai
            let region = settings?.apiRegion ?? .global
            return try await ZaiUsageFetcher.fetchUsageWithModelUsage(
                apiKey: apiKey,
                region: region,
                usageScope: settings?.usageScope,
                teamContext: settings?.teamContext,
                environment: context.env).toUsageSnapshot()
        }
        #if canImport(JavaScriptCore)
        return ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                let swift = APITokenFetchStrategy(
                    id: "zai.api",
                    resolveToken: { ProviderTokenResolver.zaiToken(environment: $0) },
                    missingCredentialsError: { ZaiSettingsError.missingToken },
                    loadUsage: loadUsage)
                guard ProviderPluginPrototype.isEnabled(environment: context.env) else { return [swift] }
                return [
                    ScriptFetchStrategy(
                        id: "zai.js",
                        provider: .zai,
                        bundledPlugin: "zai",
                        secretKey: ZaiSettingsReader.apiTokenKey,
                        resolveValues: { context in
                            let settings = context.settings?.zai
                            let region = settings?.apiRegion ?? .global
                            guard let token = ZaiSettingsReader.apiToken(
                                for: region,
                                environment: context.env)
                            else { return nil }
                            var plainValues = [
                                "Z_AI_REGION": region.rawValue,
                                "Z_AI_USAGE_SCOPE": (settings?.usageScope ?? .personal).rawValue,
                            ]
                            if let team = settings?.teamContext {
                                plainValues["Z_AI_ORGANIZATION"] = team.organizationID
                                plainValues["Z_AI_PROJECT"] = team.projectID
                            }
                            return ScriptFetchStrategy.Values(
                                settings: plainValues,
                                secrets: [ZaiSettingsReader.apiTokenKey: token])
                        }),
                    swift,
                ]
            }))
        #else
        return .apiToken(
            strategyID: "zai.api",
            resolveToken: { ProviderTokenResolver.zaiToken(environment: $0) },
            missingCredentialsError: { ZaiSettingsError.missingToken },
            loadUsage: loadUsage)
        #endif
    }
}

struct ZaiAPIFetchStrategy: ProviderFetchStrategy {
    let id = "zai.api"
    let kind: ProviderFetchKind = .apiToken
    private let transport: any ProviderHTTPTransport
    private let homeDirectory: URL

    init(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
    {
        self.transport = transport
        self.homeDirectory = homeDirectory
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        ZaiSettingsReader.apiToken(
            for: self.region(context),
            environment: context.env,
            homeDirectory: self.homeDirectory) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let settings = context.settings?.zai
        let region = self.region(context)
        guard let apiKey = ZaiSettingsReader.apiToken(
            for: region,
            environment: context.env,
            homeDirectory: self.homeDirectory)
        else {
            throw ZaiSettingsError.missingToken
        }
        let usage = try await ZaiUsageFetcher.fetchUsageWithModelUsage(
            apiKey: apiKey,
            region: region,
            usageScope: settings?.usageScope,
            teamContext: settings?.teamContext,
            environment: context.env,
            transport: self.transport)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private func region(_ context: ProviderFetchContext) -> ZaiAPIRegion {
        context.settings?.zai?.apiRegion ?? .global
    }
}
