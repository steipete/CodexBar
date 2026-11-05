import Foundation

public enum SiliconFlowProviderDescriptor {
    static let diagnosticMessages = [
        "Check your API key in Settings.",
        "SiliconFlow API origin must be https://api.siliconflow.cn or https://api.siliconflow.com.",
        "SiliconFlow refused the balance query. Check the balance in the SiliconFlow console.",
        "SiliconFlow request failed. Try refreshing later.",
        "SiliconFlow is rate limiting requests. Try again later.",
        "SiliconFlow returned an unrecognized response. Update CodexBar and try again.",
    ]

    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .siliconflow,
        displayName: "SiliconFlow",
        sessionLabel: "Balance",
        weeklyLabel: "Balance",
        balanceOnly: true,
        dashboardURL: "https://cloud.siliconflow.cn",
        color: .init(hex: 0x6E29F5),
        confetti: [0x6E29F5, 0xE8DDFF],
        noDataMessage: "No cost history data.",
        history: .unavailable,
        burnDownWidgetSelectable: false,
        environmentKey: SiliconFlowSettingsReader.apiKeyEnvironmentKey,
        missingCredentialMessage: { _ in UsageFormatter.localized("Check your API key in Settings.") },
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
        scriptSettings: { _ in
            let messages = Dictionary(uniqueKeysWithValues: Self.diagnosticMessages.map {
                ($0, UsageFormatter.localized($0))
            })
            let data = try? JSONEncoder().encode(messages)
            return ["MESSAGES": data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"]
        },
        validateContext: { context in
            try SiliconFlowSettingsReader.validate(environment: context.env)
        },
        apiKeyField: .init(
            id: "siliconflow-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file.",
            placeholder: "Paste API key…",
            action: ("siliconflow-dashboard", "Open regional API keys", "https://cloud.siliconflow.cn/account/ak")),
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
