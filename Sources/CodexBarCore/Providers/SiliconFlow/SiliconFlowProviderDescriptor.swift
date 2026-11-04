import Foundation

public enum SiliconFlowProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .siliconflow,
        displayName: "SiliconFlow",
        sessionLabel: "Balance",
        weeklyLabel: "Balance",
        balanceOnly: true,
        dashboardURL: "https://cloud.siliconflow.cn",
        color: .init(hex: 0x4D6BFE),
        confetti: [0x4D6BFE, 0xEEF0FF],
        noDataMessage: "SiliconFlow cost history is not available.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        environmentKey: SiliconFlowSettingsReader.apiKeyEnvironmentKey,
        missingCredentialMessage: { _ in "Check your SiliconFlow API key in Settings." },
        configValidator: { config in
            guard let host = config.sanitizedEnterpriseHost else { return [] }
            guard SiliconFlowSettingsReader.normalizedOrigin(host) != nil else {
                return [CodexBarConfigIssue(
                    severity: .error,
                    provider: .siliconflow,
                    field: "enterpriseHost",
                    code: "siliconflow_api_origin_invalid",
                    message: SiliconFlowSettingsReader.invalidOriginMessage)]
            }
            return []
        },
        presentation: ProviderUsagePresentation(menuBarBalanceDetailLabels: ["Total balance"]),
        validateContext: { context in
            try SiliconFlowSettingsReader.validate(environment: context.env)
        },
        apiKeyField: .init(
            id: "siliconflow-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file.",
            placeholder: "Paste API key…",
            action: ("siliconflow-dashboard", "Open SiliconFlow", "https://cloud.siliconflow.cn/account/ak")),
        endpoint: .init(
            environmentKey: SiliconFlowSettingsReader.baseURLEnvironmentKey,
            requirement: .optional(defaultURL: SiliconFlowSettingsReader.chinaOrigin),
            resolve: SiliconFlowSettingsReader.baseURL(environment:),
            field: .init(
                id: "siliconflow-api-origin",
                title: "API URL",
                subtitle: "China (CNY) is the default. International accounts use https://api.siliconflow.com (USD).",
                placeholder: "https://api.siliconflow.cn")),
        showsAPIDetail: true,
        availability: .configuredKey)
}
