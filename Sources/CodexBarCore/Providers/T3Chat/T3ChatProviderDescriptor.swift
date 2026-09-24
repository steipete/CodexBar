import Foundation

public enum T3ChatProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .t3chat,
            settingsSection: .init(T3ChatProviderSettingsKey.self, cookieSettings: T3ChatProviderSettings.self),
            metadata: ProviderMetadata(
                id: .t3chat,
                displayName: "T3 Chat",
                sessionLabel: "Base",
                weeklyLabel: "Overage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show T3 Chat usage",
                cliName: "t3chat",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: ["free": "Free", "pro": "Pro", "team": "Team"],
                debugLogUnavailableMessage: "T3 Chat debug log not yet implemented",
                debugPane: ProviderDebugPaneCapabilities(errorSimulationOrder: 6),
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://t3.chat/settings/customization",
                subscriptionDashboardURL: "https://t3.chat/settings/subscription",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .t3chat),
                iconResourceName: "ProviderIcon-t3chat",
                color: ProviderColor(red: 245 / 255, green: 102 / 255, blue: 71 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x970B72),
                    ProviderColor(hex: 0xE6229C),
                    ProviderColor(hex: 0xFEA0F6),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "T3 Chat cost summary is not supported." }),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "t3chat",
                aliases: ["t3-chat", "t3"],
                versionDetector: nil))
    }

    private static let forwardedManualHeaders = [
        "accept": "Accept",
        "accept-language": "Accept-Language",
        "cache-control": "Cache-Control",
        "pragma": "Pragma",
        "priority": "Priority",
        "referer": "Referer",
        "sec-fetch-dest": "Sec-Fetch-Dest",
        "sec-fetch-mode": "Sec-Fetch-Mode",
        "sec-fetch-site": "Sec-Fetch-Site",
        "trpc-accept": "trpc-accept",
        "user-agent": "User-Agent",
        "x-client-context": "x-client-context",
        "x-deployment-id": "X-Deployment-Id",
        "x-trpc-batch": "x-trpc-batch",
        "x-trpc-source": "x-trpc-source",
    ]

    static func pluginValues(_ context: ProviderFetchContext) -> ScriptFetchStrategy.Values? {
        let source = context.settings?.t3chat?.cookieSource ?? .auto
        guard source != .off else { return nil }
        let raw = source == .manual ? context.settings?.t3chat?.manualCookieHeader : nil
        let fields = CurlCaptureParser.headerFields(from: raw ?? "")
        let cookie = CookieHeaderNormalizer.normalize(
            CurlCaptureParser.headerValue(named: "Cookie", in: fields) ?? raw)
        if source == .manual, cookie == nil { return nil }
        let headers = CurlCaptureParser.forwardedHeaders(from: fields, allowlist: self.forwardedManualHeaders)
        let encodedHeaders = (try? JSONEncoder().encode(headers)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .init(
            settings: ["TIMEOUT_SECONDS": String(min(90, max(1, context.webTimeout)))],
            secrets: ["MANUAL_COOKIE": cookie ?? "", "CAPTURED_HEADERS": encodedHeaders])
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .web],
            pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                [ScriptFetchStrategy(
                    id: "t3chat.js",
                    provider: .t3chat,
                    bundledPlugin: "t3chat",
                    sourceLabel: "web",
                    kind: .web,
                    timeout: max(20, min(90, context.webTimeout) + 5),
                    resolveValues: Self.pluginValues,
                    isEnabled: { _ in true })]
            }))
    }
}
