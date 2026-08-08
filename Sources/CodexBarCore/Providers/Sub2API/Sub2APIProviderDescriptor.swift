import Foundation

public enum Sub2APIProviderDescriptor {
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: Sub2APISettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [.enterpriseHost(Sub2APISettingsReader.baseURLEnvironmentKey)],
        resolve: Sub2APISettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "Group API keys",
            subtitle: "Store one labeled sub2api API key for each group you want to monitor.",
            placeholder: "Paste sub2api API key…",
            injection: .environment(key: Sub2APISettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        configValidator: { config in
            guard let raw = config.sanitizedEnterpriseHost,
                  Sub2APISettingsReader.baseURL(environment: [
                      Sub2APISettingsReader.baseURLEnvironmentKey: raw,
                  ]) == nil
            else { return [] }
            return [CodexBarConfigIssue(
                severity: .error,
                provider: .sub2api,
                field: "enterpriseHost",
                code: "invalid_enterprise_host",
                message: Sub2APISettingsError.invalidBaseURL.errorDescription ?? "Invalid sub2api base URL.")]
        },
        missingCredentialMessage: { environment in
            Sub2APISettingsReader.apiKey(environment: environment) == nil
                ? Sub2APISettingsReader.missingCredentialsMessage
                : Sub2APISettingsReader.missingBaseURLMessage
        })

    public static func primaryLabel(snapshot: UsageSnapshot) -> String? {
        snapshot.secondary != nil ? "Daily quota" : nil
    }

    public static let descriptor = ProviderDescriptor(
        id: .sub2api,
        credentials: Self.credentials,
        config: ProviderConfigCapabilities(supportsEnterpriseHost: true),
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
            sharePlanLabels: [
                "free": "Free", "pro": "Pro", "team": "Team", "claude team": "Team",
                "enterprise": "Enterprise", "wallet plan": "Wallet",
            ],
            debugLogUnavailableMessage: "sub2api debug log not yet implemented",
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
        presentation: ProviderUsagePresentation(
            rateWindowLabeler: { metadata, snapshot, _ in
                ProviderRateWindowLabels(
                    primary: Self.primaryLabel(snapshot: snapshot) ?? metadata.sessionLabel,
                    secondary: metadata.weeklyLabel,
                    tertiary: metadata.opusLabel ?? "Sonnet",
                    showsTertiary: metadata.supportsOpus)
            },
            menuCard: ProviderMenuCardPresentation(usesRawPrimaryResetDescription: true),
            menu: ProviderMenuDescriptorPresentation(
                primaryDescriptionIsDetail: { _ in true },
                secondaryDescriptionMode: .resetOverride,
                tertiaryDescriptionOverridesReset: true)),
        fetchPlan: Self.fetchPlan(),
        cli: ProviderCLIConfig(
            name: "sub2api",
            aliases: ["sub-2-api"],
            versionDetector: nil))

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [ScriptFetchStrategy(
                    id: "sub2api.js",
                    provider: .sub2api,
                    bundledPlugin: "sub2api",
                    secretKey: Sub2APISettingsReader.apiKeyEnvironmentKey,
                    sourceLabel: "api",
                    resolveValues: { context in
                        guard let key = self.credentials.resolveToken(environment: context.env)?.token,
                              let baseURL = Sub2APISettingsReader.baseURL(environment: context.env)
                        else { return nil }
                        return ScriptFetchStrategy.Values(
                            settings: [Sub2APISettingsReader.baseURLEnvironmentKey: baseURL.absoluteString],
                            secrets: [Sub2APISettingsReader.apiKeyEnvironmentKey: key])
                    },
                    isEnabled: { _ in true })]
            }))
    }
}
