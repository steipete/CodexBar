import Foundation

public enum Sub2APIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .sub2api,
        displayName: "sub2api",
        sessionLabel: "Quota",
        weeklyLabel: "Weekly quota",
        opusLabel: "Monthly quota",
        creditsHint: "Reads key quota, subscription limits, usage, and wallet balance from /v1/usage.",
        sharePlanLabels: [
            "free": "Free", "pro": "Pro", "team": "Team", "claude team": "Team",
            "enterprise": "Enterprise", "wallet plan": "Wallet",
        ],
        debugLogUnavailableMessage: "sub2api debug log not yet implemented",
        dashboardURL: nil,
        color: ProviderColor(hex: 0x2DC6D8),
        confetti: [0x1F62FF, 0x60EDF6, 0x74F9B0],
        noDataMessage: "sub2api spend is reported by its usage API.",
        environmentKey: Sub2APISettingsReader.apiKeyEnvironmentKey,
        missingCredentialMessage: { environment in
            Sub2APISettingsReader.apiKey(environment: environment) == nil
                ? Sub2APISettingsReader.missingCredentialsMessage
                : Sub2APISettingsReader.missingBaseURLMessage
        },
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
        presentation: ProviderUsagePresentation(
            rateWindowLabeler: { metadata, snapshot, _ in
                ProviderRateWindowLabels(
                    primary: Self.primaryLabel(snapshot: snapshot) ?? metadata.sessionLabel,
                    secondary: metadata.weeklyLabel,
                    tertiary: metadata.opusLabel ?? "Sonnet",
                    showsTertiary: metadata.supportsOpus)
            },
            menuCard: ProviderMenuCardPresentation(
                extraRateWindowUsesResetDescriptionAsDetail: { _ in true },
                usesRawPrimaryResetDescription: true),
            menu: ProviderMenuDescriptorPresentation(
                primaryDescriptionIsDetail: { _ in true },
                secondaryDescriptionMode: .resetOverride,
                tertiaryDescriptionOverridesReset: true)),
        aliases: ["sub-2-api"],
        apiKeyField: .init(
            id: "sub2api-api-key",
            title: "Fallback API key",
            subtitle: "Used when no group API key account is selected.",
            placeholder: "sk-…"),
        endpoint: .init(
            environmentKey: Sub2APISettingsReader.baseURLEnvironmentKey,
            requirement: .required(.validated),
            resolve: Sub2APISettingsReader.baseURL,
            field: .init(
                id: "sub2api-base-url",
                title: "Base URL",
                subtitle: "Base URL of your sub2api instance. HTTPS is required except for local loopback testing.",
                placeholder: "https://sub2api.example.com")),
        showsAPIDetail: true,
        availability: .environmentKey,
        observesTokenAccounts: true)

    public static func primaryLabel(snapshot: UsageSnapshot) -> String? {
        snapshot.secondary != nil ? "Daily quota" : nil
    }
}
