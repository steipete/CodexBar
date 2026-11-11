import Foundation

public enum ClaudePlatformAWSProviderDescriptor {
    public static let accessKeyIDEnvironmentKey = "ANTHROPIC_AWS_ACCESS_KEY_ID"
    public static let secretAccessKeyEnvironmentKey = "ANTHROPIC_AWS_SECRET_ACCESS_KEY"
    public static let regionsEnvironmentKey = "ANTHROPIC_AWS_REGIONS"
    /// Each configured region costs up to five sequential requests.
    static let timeout: TimeInterval = 60

    public static let spec = PluginProviderSpec(
        id: .claudeplatformaws,
        displayName: "Claude Platform on AWS",
        sessionLabel: "Spend",
        weeklyLabel: "Spend",
        dashboardURL: nil,
        color: .init(hex: 0xD97757),
        confetti: [0xD97757, 0xFF9900],
        noDataMessage: "Claude Platform on AWS spend history needs the cost and usage analytics permissions.",
        supportsTokenCost: true,
        environmentKey: Self.accessKeyIDEnvironmentKey,
        missingCredentialMessage: { _ in
            "Set an AWS access key ID, secret access key, and regions for Claude Platform on AWS in Settings."
        },
        additionalProjections: [.init(
            key: Self.secretAccessKeyEnvironmentKey,
            value: { $0.pluginSecrets?[Self.secretAccessKeyEnvironmentKey] })],
        menuBarMetrics: .init(supported: [.automatic]),
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

    public static let descriptor = Self.spec.makeDescriptor(fetchPlan: ProviderFetchPlan(
        sourceModes: [.auto, .api],
        pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
            [ScriptFetchStrategy(
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
                        settings: [Self.regionsEnvironmentKey: cleaned(Self.regionsEnvironmentKey) ?? ""],
                        secrets: [Self.accessKeyIDEnvironmentKey, Self.secretAccessKeyEnvironmentKey]
                            .reduce(into: [:]) { values, key in values[key] = cleaned(key) })
                },
                isEnabled: { _ in true })]
        })))
}
