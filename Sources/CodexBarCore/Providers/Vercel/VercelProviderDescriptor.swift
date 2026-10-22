import Foundation

public enum VercelProviderDescriptor {
    static let tokenKey = "VERCEL_ACCESS_TOKEN"
    static let teamKey = "VERCEL_TEAM_ID"

    /// The plugin host binds one auth secret per manifest, so the personal budget is a second bundled script.
    public static let descriptor = Self.spec.makeDescriptor(fetchPlan: ProviderFetchPlan(
        sourceModes: [.auto, .api],
        pipeline: ProviderFetchPipeline(resolveStrategies: { context in
            Self.budgetValues(context) == nil ? [Self.spec.makeStrategy()] : [Self.budgetStrategy()]
        })))

    public static let spec = PluginProviderSpec(
        id: .vercel,
        displayName: "Vercel AI Gateway",
        sessionLabel: "Personal budget",
        weeklyLabel: "Balance",
        toggleTitle: "Show Vercel AI Gateway balance",
        balanceOnly: true,
        dashboardURL: "https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai-gateway",
        color: .init(hex: 0xFFFFFF),
        confetti: [0xFFFFFF, 0xA3A3A3],
        progressColorStyle: .label,
        noDataMessage: "Vercel AI Gateway cost history is not available.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        environmentKey: "AI_GATEWAY_API_KEY",
        missingCredentialMessage: { _ in
            "Set a Vercel AI Gateway API key, or a Vercel access token and Team ID for your personal budget."
        },
        additionalProjections: [.init(key: Self.tokenKey, value: { $0.pluginSecrets?[Self.tokenKey] })],
        config: ProviderConfigCapabilities(workspaceIDValidationOrder: 9),
        presentation: ProviderUsagePresentation(menuBarBalanceDetailLabels: ["Available balance"]),
        apiKeyField: .init(
            id: "vercel-api-key",
            title: "Vercel AI Gateway API key",
            subtitle: "Saved in CodexBar's local config file. Or set AI_GATEWAY_API_KEY."),
        workspaceField: .init(
            environmentKey: Self.teamKey,
            field: .init(
                id: "vercel-team-id",
                title: "Team ID",
                subtitle: "Required with a Vercel access token. Or set VERCEL_TEAM_ID.",
                placeholder: nil)))

    static func budgetValues(_ context: ProviderFetchContext) -> ScriptFetchStrategy.Values? {
        guard let token = SettingsValue.cleaned(context.env[tokenKey]) else { return nil }
        return .init(
            settings: [Self.teamKey: SettingsValue.cleaned(context.env[Self.teamKey]) ?? ""],
            secrets: [Self.tokenKey: token])
    }

    static func budgetStrategy(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> ScriptFetchStrategy
    {
        ScriptFetchStrategy(
            id: "vercel-budget.js",
            provider: .vercel,
            bundledPlugin: "vercel-budget",
            secretKey: self.tokenKey,
            sourceLabel: "api",
            transport: transport,
            resolveValues: self.budgetValues,
            isEnabled: { _ in true })
    }
}
