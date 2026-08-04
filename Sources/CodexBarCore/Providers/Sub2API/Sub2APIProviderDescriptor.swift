import Foundation

public enum Sub2APIProviderDescriptor {
    public static func primaryLabel(details: Sub2APIUsageDetails?) -> String? {
        details?.kind == .subscription ? "Daily quota" : nil
    }

    public static let descriptor = ProviderDescriptor(
        id: .sub2api,
        metadata: ProviderMetadata(
            id: .sub2api,
            displayName: "sub2api",
            sessionLabel: "Quota",
            weeklyLabel: "Weekly quota",
            opusLabel: "Monthly quota",
            supportsOpus: true,
            supportsCredits: false,
            creditsHint: "Reads key quota, subscription limits, usage, and wallet balance from /v1/usage.",
            toggleTitle: "Show sub2api usage",
            cliName: "sub2api",
            defaultEnabled: false,
            widgetSelectable: false,
            dashboardURL: nil,
            statusPageURL: nil),
        branding: ProviderBranding(
            iconStyle: .init(provider: .sub2api),
            iconResourceName: "ProviderIcon-sub2api",
            color: ProviderColor(red: 45 / 255, green: 198 / 255, blue: 216 / 255),
            confettiPalette: [
                ProviderColor(hex: 0x1F62FF),
                ProviderColor(hex: 0x60EDF6),
                ProviderColor(hex: 0x74F9B0),
            ]),
        tokenCost: ProviderTokenCostConfig(
            supportsTokenCost: false,
            noDataMessage: { "sub2api spend is reported by its usage API." }),
        fetchPlan: Self.fetchPlan(),
        cli: ProviderCLIConfig(
            name: "sub2api",
            aliases: ["sub-2-api"],
            versionDetector: nil))

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                let swift = Sub2APIAPIFetchStrategy()
                #if canImport(JavaScriptCore)
                guard ProviderPluginPrototype.isEnabled(environment: context.env) else { return [swift] }
                return [
                    ScriptFetchStrategy(
                        id: "sub2api.js",
                        provider: .sub2api,
                        bundledPlugin: "sub2api",
                        secretKey: Sub2APISettingsReader.apiKeyEnvironmentKey,
                        resolveValues: { context in
                            guard let key = Sub2APISettingsReader.apiKey(environment: context.env),
                                  let baseURL = Sub2APISettingsReader.baseURL(environment: context.env)
                            else { return nil }
                            return ScriptFetchStrategy.Values(
                                settings: [Sub2APISettingsReader.baseURLEnvironmentKey: baseURL.absoluteString],
                                secrets: [Sub2APISettingsReader.apiKeyEnvironmentKey: key])
                        }),
                    swift,
                ]
                #else
                return [swift]
                #endif
            }))
    }
}

struct Sub2APIAPIFetchStrategy: ProviderFetchStrategy {
    let id = "sub2api.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Sub2APISettingsReader.apiKey(environment: context.env) != nil &&
            Sub2APISettingsReader.baseURL(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Sub2APISettingsReader.apiKey(environment: context.env) else {
            throw Sub2APIUsageError.missingCredentials
        }
        guard let baseURL = Sub2APISettingsReader.baseURL(environment: context.env) else {
            throw Sub2APIUsageError.missingBaseURL
        }
        let usage = try await Sub2APIUsageFetcher.fetchUsage(apiKey: apiKey, baseURL: baseURL)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
