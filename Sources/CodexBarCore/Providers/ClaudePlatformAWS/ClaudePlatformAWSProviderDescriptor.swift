import Foundation

public enum ClaudePlatformAWSProviderDescriptor {
    public static let accessKeyIDEnvironmentKey = "ANTHROPIC_AWS_ACCESS_KEY_ID"
    public static let secretAccessKeyEnvironmentKey = "ANTHROPIC_AWS_SECRET_ACCESS_KEY"
    public static let regionsEnvironmentKey = "ANTHROPIC_AWS_REGIONS"
    public static let monthlyBudgetEnvironmentKey = "ANTHROPIC_AWS_MONTHLY_BUDGET"
    public static let dailyBudgetEnvironmentKey = "ANTHROPIC_AWS_DAILY_BUDGET"
    /// `local` (the default) or `utc`: where days and months begin.
    public static let timeZoneEnvironmentKey = "ANTHROPIC_AWS_TIME_ZONE"
    /// Each configured region costs a handful of sequential requests, and more when a series spans several
    /// pages, as the hourly series behind local-time days can.
    static let timeout: TimeInterval = 120

    public static let spec = PluginProviderSpec(
        id: .claudeplatformaws,
        displayName: "Claude Platform on AWS",
        // Windows exist only when the optional budgets are set: today's spend, then the month's.
        sessionLabel: "Today",
        weeklyLabel: "This month",
        dashboardURL: nil,
        color: .init(hex: 0xD97757),
        confetti: [0xD97757, 0xFF9900],
        noDataMessage: "Claude Platform on AWS spend history needs the cost and usage analytics permissions.",
        supportsTokenCost: true,
        // The history is the analytics API's own figures, not an estimate from local logs.
        tokenCostHintLines: [.literal("Anthropic analytics · may differ from AWS invoice")],
        environmentKey: Self.accessKeyIDEnvironmentKey,
        missingCredentialMessage: { _ in
            "Set an AWS access key ID, secret access key, and regions for Claude Platform on AWS in Settings."
        },
        additionalProjections: [
            .init(
                key: Self.secretAccessKeyEnvironmentKey,
                value: { $0.pluginSecrets?[Self.secretAccessKeyEnvironmentKey] }),
            .init(
                key: Self.monthlyBudgetEnvironmentKey,
                value: { $0.pluginSettings?[Self.monthlyBudgetEnvironmentKey] }),
            .init(
                key: Self.dailyBudgetEnvironmentKey,
                value: { $0.pluginSettings?[Self.dailyBudgetEnvironmentKey] }),
            .init(
                key: Self.timeZoneEnvironmentKey,
                value: { $0.pluginSettings?[Self.timeZoneEnvironmentKey] }),
        ],
        // The projected 30-day history drives the inline spend chart and its Today/30-day summary.
        presentation: ProviderUsagePresentation(menuCard: ProviderMenuCardPresentation(
            supportsInlineTokenCostDashboard: true)),
        apiKeyField: .init(
            id: "claudeplatformaws-access-key-id",
            title: "Access key ID",
            subtitle: "Long-lived IAM user key allowed to read Claude Platform on AWS cost and usage. "
                + "Or set ANTHROPIC_AWS_ACCESS_KEY_ID.",
            placeholder: "AKIA..."),
        workspaceField: .init(
            environmentKey: Self.regionsEnvironmentKey,
            field: .init(
                id: "claudeplatformaws-regions",
                title: "Regions",
                subtitle: "Required. Comma-separated AWS regions that hold your workspaces. "
                    + "Or set ANTHROPIC_AWS_REGIONS.",
                placeholder: "us-east-1")))

    private static let requiredKeys = [
        Self.accessKeyIDEnvironmentKey,
        Self.secretAccessKeyEnvironmentKey,
        Self.regionsEnvironmentKey,
    ]

    /// One strategy for the process: it owns the plugin runtime, whose in-memory cache holds each region's last
    /// result between refreshes. A strategy per refresh would start every refresh with an empty cache.
    private static let strategy = ScriptFetchStrategy(
        id: "claudeplatformaws.js",
        provider: .claudeplatformaws,
        bundledPlugin: "claudeplatformaws",
        sourceLabel: "api",
        timeout: Self.timeout,
        validateContext: { context in
            guard Self.requiredKeys.allSatisfy({ SettingsValue.cleaned(context.env[$0]) != nil }) else {
                throw ProviderFetchClassifiedError(
                    kind: .missingCredential,
                    message: "Claude Platform on AWS requires an AWS access key ID, secret access key, "
                        + "and at least one region.")
            }
        },
        resolveValues: { context in
            let cleaned: (String) -> String? = { SettingsValue.cleaned(context.env[$0]) }
            return .init(
                settings: [
                    Self.regionsEnvironmentKey,
                    Self.monthlyBudgetEnvironmentKey,
                    Self.dailyBudgetEnvironmentKey,
                    Self.timeZoneEnvironmentKey,
                ].reduce(into: [:]) { values, key in values[key] = cleaned(key) ?? "" },
                secrets: [Self.accessKeyIDEnvironmentKey, Self.secretAccessKeyEnvironmentKey]
                    .reduce(into: [:]) { values, key in values[key] = cleaned(key) })
        },
        isEnabled: { _ in true })

    public static let descriptor = Self.spec.makeDescriptor(fetchPlan: ProviderFetchPlan(
        sourceModes: [.auto, .api],
        pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [Self.strategy] })))
}
