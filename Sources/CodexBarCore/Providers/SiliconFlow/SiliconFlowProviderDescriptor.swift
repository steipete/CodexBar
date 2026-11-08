import Foundation

public enum SiliconFlowProviderDescriptor {
    static let diagnosticMessages = [
        "Check your API key in Settings.",
        "SiliconFlow API origin must be https://api.siliconflow.cn or https://api.siliconflow.com.",
        "SiliconFlow refused the balance query. Check the balance in the SiliconFlow console.",
        "SiliconFlow request failed. Try refreshing later.",
        "SiliconFlow is rate limiting requests. Try again later.",
        "SiliconFlow returned an unrecognized response. Update CodexBar and try again.",
        "Sign in to cloud.siliconflow.cn in your browser, then refresh CodexBar.",
        "The SiliconFlow China balance API was retired. "
            + "Set the source to Auto or Web and sign in to cloud.siliconflow.cn.",
        "SiliconFlow denied access to the console balance (HTTP 403).",
    ]

    public static let descriptor = Self.spec.makeDescriptor(fetchPlan: ProviderFetchPlan(
        sourceModes: [.auto, .web, .api],
        pipeline: ProviderFetchPipeline(resolveStrategies: { context in
            // The China public balance API was retired; its console balance is reachable only with a browser session.
            // International accounts keep the API-key path, and their web console has not been verified.
            let china = SiliconFlowSettingsReader.baseURL(environment: context.env)
                == SiliconFlowSettingsReader.chinaOrigin
            switch context.sourceMode {
            case .api: return [Self.spec.makeStrategy()]
            case .web: return china ? [Self.webStrategy(context)] : []
            case .auto: return [china ? Self.webStrategy(context) : Self.spec.makeStrategy()]
            case .cli, .oauth: return []
            }
        })))

    private static func webStrategy(_ context: ProviderFetchContext) -> ScriptFetchStrategy {
        ScriptFetchStrategy(
            id: "siliconflow.web",
            provider: .siliconflow,
            bundledPlugin: "siliconflow-web",
            sourceLabel: "web",
            kind: .web,
            timeout: context.webTimeout,
            resolveValues: { .init(settings: Self.spec.scriptSettings($0)) },
            isEnabled: { _ in true })
    }

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
        webSource: .init(
            settingsSection: .init(SiliconFlowProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            browserSupportExemption: { _, _, settings in
                settings?[SiliconFlowProviderSettingsKey.self]?.cookieSource == .manual
            },
            field: .init(
                id: "siliconflow-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a billing-page request.",
                placeholder: "Cookie: …",
                action: (
                    id: "siliconflow-open-billing",
                    title: "Open Dashboard",
                    url: "https://cloud.siliconflow.cn/me/expensebill")),
            picker: .init(
                id: "siliconflow-cookie-source",
                allowsOff: true,
                auto: .localized("Automatic imports browser cookies."),
                manual: .localized("Paste a Cookie header captured from %@.", argument: "cloud.siliconflow.cn"),
                off: .localized("%@ cookies are disabled.", argument: "SiliconFlow"),
                showsRefreshAction: true)),
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

public enum SiliconFlowProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.siliconflow
    public typealias Section = CookieProviderSettings
}
