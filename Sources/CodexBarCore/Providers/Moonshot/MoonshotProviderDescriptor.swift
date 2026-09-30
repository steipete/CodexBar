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
                color: ProviderColor(hex: 0x205DEB),
                confettiPalette: [
                    ProviderColor(hex: 0x121212),
                    ProviderColor(hex: 0x305140),
                    ProviderColor(hex: 0x9F9F9F),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Moonshot / Kimi Open Platform cost summary is not available." }),
            presentation: ProviderUsagePresentation(
                identityPresenter: { provider, snapshot in
                    guard let balance = snapshot.loginMethod(for: provider), !balance.isEmpty else {
                        return ProviderIdentityPresentation(badge: nil, plan: nil)
                    }
                    return ProviderIdentityPresentation(badge: balance, plan: balance)
                },
                planRow: ProviderPlanRowPresentation(label: "Balance", stripsBalancePrefix: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [Self.scriptStrategy()] })),
            cli: ProviderCLIConfig(
                name: "moonshot",
                aliases: [],
                versionDetector: nil),
            configNormalizer: { config in
                guard config.sanitizedAPIKey != nil, config.sanitizedAPIKeyRegion == nil else { return }
                config.apiKeyRegion = config.sanitizedRegion ?? MoonshotRegion.international.rawValue
            })
    }

    static func scriptStrategy(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> ScriptFetchStrategy
    {
        ScriptFetchStrategy(
            id: "moonshot.js",
            provider: .moonshot,
            bundledPlugin: "moonshot",
            secretKey: "MOONSHOT_API_KEY",
            sourceLabel: "api",
            transport: transport,
            validateContext: { context in
                guard Self.apiKey(context) != nil else {
                    throw ProviderFetchClassifiedError(kind: .missingCredential, message: "Missing Moonshot API key.")
                }
            },
            resolveValues: { context in
                guard let apiKey = Self.apiKey(context) else { return nil }
                return .init(
                    settings: ["BASE_URL": Self.region(context).apiBaseURLString],
                    secrets: ["MOONSHOT_API_KEY": apiKey])
            },
            isEnabled: { _ in true })
    }

    private static func apiKey(_ context: ProviderFetchContext) -> String? {
        MoonshotSettingsReader.apiKey(for: self.region(context), environment: context.env)
    }

    private static func region(_ context: ProviderFetchContext) -> MoonshotRegion {
        context.settings?.moonshot?.region ?? MoonshotSettingsReader.region(environment: context.env)
    }
}
