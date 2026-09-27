import Foundation

public enum T3ChatProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .t3chat,
        displayName: "T3 Chat",
        sessionLabel: "Base",
        weeklyLabel: "Overage",
        sharePlanLabels: ["free": "Free", "pro": "Pro", "team": "Team"],
        debugLogUnavailableMessage: "T3 Chat debug log not yet implemented",
        debugPane: ProviderDebugPaneCapabilities(errorSimulationOrder: 6),
        dashboardURL: "https://t3.chat/settings/customization",
        subscriptionDashboardURL: "https://t3.chat/settings/subscription",
        color: .init(hex: 0xF56647),
        confetti: [0x970B72, 0xE6229C, 0xFEA0F6],
        noDataMessage: "T3 Chat cost summary is not supported.",
        aliases: ["t3-chat", "t3"],
        webSource: .init(
            settingsSection: .init(T3ChatProviderSettingsKey.self, cookieSettings: T3ChatProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            timeout: .web(minimum: 20, maximum: 90, padding: 5, nonFinite: nil),
            resolveValues: Self.pluginValues,
            field: .init(
                id: "t3chat-cookie",
                title: "T3 Chat cookie",
                subtitle: "Paste a Cookie header or full cURL capture from T3 Chat settings.",
                placeholder: "Cookie: ...",
                action: (
                    id: "t3chat-open-settings",
                    title: "Open T3 Chat Settings",
                    url: "https://t3.chat/settings/customization")),
            picker: .init(
                id: "t3chat-cookie-source",
                allowsOff: false,
                auto: .localized("Automatically imports browser cookies."),
                manual: .localized("Paste a Cookie header or cURL capture from %@.", argument: "T3 Chat settings"),
                off: .localized("Paste a Cookie header or cURL capture from %@.", argument: "T3 Chat settings"))))

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
}
