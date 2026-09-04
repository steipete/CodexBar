import Foundation

public enum MoonshotProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        supportsAPIKeyOverride: true,
        usesRegion: true,
        environmentOverride: { base, config in
            guard let config,
                  let apiKey = config.sanitizedAPIKey,
                  let region = config.sanitizedAPIKeyRegion
            else { return base }
            var environment = base
            environment[MoonshotSettingsReader.configAPIKeyEnvironmentKey] = apiKey
            environment[MoonshotSettingsReader.configAPIKeyRegionEnvironmentKey] = region
            return environment
        },
        tokenResolver: { kind, environment, _ in
            guard kind == .primary, let token = MoonshotSettingsReader.apiKey(environment: environment) else {
                return nil
            }
            return ProviderTokenResolution(token: token, source: .environment)
        },
        authDetector: { environment, _ in
            MoonshotSettingsReader.apiKey(environment: environment) == nil ? [] : ["api"]
        },
        configValidator: ProviderCredentialAdapter.regionValidator(
            displayName: "Moonshot",
            isValid: { MoonshotRegion(rawValue: $0) != nil }))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .moonshot,
            settingsSection: .init(MoonshotProviderSettingsKey.self, credentialSettings: { context in
                let region = context.config?.sanitizedRegion.flatMap(MoonshotRegion.init(rawValue:))
                    ?? (context.config?.sanitizedRegion == nil ? nil : .international)
                return MoonshotProviderSettings(region: region)
            }),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .moonshot,
                displayName: "Moonshot / Kimi Open Platform",
                shortDisplayName: "Moonshot",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Moonshot / Kimi Open Platform balance",
                cliName: "moonshot",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                balanceOnly: true,
                browserCookieOrder: nil,
                dashboardURL: "https://platform.moonshot.ai/console/account",
                statusPageURL: nil),
            branding: ProviderBranding(
                // Provider-specific by design: Moonshot's Open Platform product deliberately uses Kimi branding.
                iconStyle: .init(provider: .kimi),
                iconResourceName: "ProviderIcon-kimi",
                color: ProviderColor(red: 0 / 255, green: 0 / 255, blue: 0 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0x305140),
                    ProviderColor(hex: 0x9F9F9F),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Moonshot / Kimi Open Platform cost summary is not available." }),
            presentation: ProviderUsagePresentation(
                planRow: ProviderPlanRowPresentation(label: "Balance", stripsBalancePrefix: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MoonshotAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "moonshot",
                aliases: [],
                versionDetector: nil),
            configNormalizer: { config in
                guard config.sanitizedAPIKey != nil, config.sanitizedAPIKeyRegion == nil else { return }
                config.apiKeyRegion = config.sanitizedRegion ?? MoonshotRegion.international.rawValue
            })
    }
}

struct MoonshotAPIFetchStrategy: ProviderFetchStrategy {
    let id = "moonshot.api"
    let kind: ProviderFetchKind = .apiToken
    private let transport: any ProviderHTTPTransport

    init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        MoonshotSettingsReader.apiKey(for: self.region(context), environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let region = self.region(context)
        guard let apiKey = MoonshotSettingsReader.apiKey(for: region, environment: context.env) else {
            throw MoonshotUsageError.missingCredentials
        }
        let usage = try await MoonshotUsageFetcher.fetchUsage(
            apiKey: apiKey,
            region: region,
            session: self.transport)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private func region(_ context: ProviderFetchContext) -> MoonshotRegion {
        context.settings?.moonshot?.region ?? MoonshotSettingsReader.region(environment: context.env)
    }
}
