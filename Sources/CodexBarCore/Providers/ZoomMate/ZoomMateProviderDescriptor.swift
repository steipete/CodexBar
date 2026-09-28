import Foundation

public enum ZoomMateProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .zoommate,
            settingsSection: .init(ZoomMateProviderSettingsKey.self, cookieSettings: ZoomMateProviderSettings.self),
            metadata: ProviderMetadata(
                id: .zoommate,
                displayName: "ZoomMate",
                sessionLabel: "Credits",
                weeklyLabel: "Credits",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Shows used/remaining credits against your ZoomMate budget cap.",
                toggleTitle: "Show ZoomMate usage",
                cliName: "zoommate",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "ZoomMate debug log not yet implemented",
                debugPane: ProviderDebugPaneCapabilities(errorSimulationOrder: 7),
                browserCookieOrder: BrowserCookieImportSupport.chromeOnly(
                    reason: "Avoid surprise permission prompts from other browser stores"),
                dashboardURL: "https://zoommate.zoom.us/#/?settings=credit-usage",
                subscriptionDashboardURL: nil,
                statusPageURL: "https://www.zoomstatus.com/",
                statusComponentAllowlist: [
                    "Zoom Meetings",
                    "ZoomMate",
                    "My Notes",
                    "Zoom Workflows",
                    "Zoom Developer Platform",
                    "Zoom Support",
                    "Zoom Website",
                ]),
            branding: ProviderBranding(
                iconStyle: .init(provider: .zoommate),
                iconResourceName: "ProviderIcon-zoommate",
                // Zoom Brand Center "Visual identity > Color", retrieved 2026-07-18:
                // https://brand.zoom.com/document/1#/visual-identity/color
                // Bloom is primary; Dawn and Midnight are supporting core colors.
                color: ProviderColor(red: 11 / 255, green: 92 / 255, blue: 255 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x0B5CFF),
                    ProviderColor(hex: 0xB4D0F8),
                    ProviderColor(hex: 0x00053D),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "ZoomMate cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    [Self.webStrategy(timeout: context.webTimeout)]
                })),
            cli: ProviderCLIConfig(
                name: "zoommate",
                aliases: [],
                versionDetector: nil))
    }
}

extension ZoomMateProviderDescriptor {
    static let hosts = ["ai.zoom.us", "zoommate.zoom.us"]

    static func capture(_ raw: String?) -> (host: String, headers: [String: String])? {
        guard let raw, let url = CurlCaptureParser.requestURL(from: raw), let host = url.host?.lowercased(),
              hosts.contains(host), url.scheme?.lowercased() == "https", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/ai-computer/api/v1/credits/status" else { return nil }
        let fields = CurlCaptureParser.headerFields(from: raw)
        let names = [
            "authorization",
            "cookie",
            "user-agent",
            "accept",
            "accept-language",
            "sec-fetch-dest",
            "sec-fetch-mode",
            "sec-fetch-site",
        ]
        let headers = CurlCaptureParser.forwardedHeaders(
            from: fields, allowlist: Dictionary(uniqueKeysWithValues: names.map { ($0, $0) }))
        guard headers["authorization"]?.isEmpty == false else { return nil }
        return (host, headers)
    }

    static func webStrategy(
        timeout: TimeInterval = 15,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> ScriptFetchStrategy
    {
        ScriptFetchStrategy(
            id: "zoommate.web",
            provider: .zoommate,
            bundledPlugin: "zoommate",
            sourceLabel: "web",
            kind: .web,
            transport: transport,
            timeout: max(30, timeout * 4),
            validateContext: { context in
                if context.settings?.zoommate?.cookieSource == .manual,
                   Self.capture(context.settings?.zoommate?.manualCookieHeader) == nil
                {
                    throw ProviderFetchClassifiedError(
                        kind: .missingCredential,
                        message: "Paste a cURL capture of the HTTPS ZoomMate credits/status request.")
                }
            }, cookieSettings: { context in
                let settings = context.settings?.zoommate
                let capture = Self.capture(settings?.manualCookieHeader)
                return .init(
                    cookieSource: settings?.cookieSource ?? .auto,
                    manualCookieHeader: capture?.headers["cookie"],
                    manualCookieOrigin: capture.map { "https://\($0.host)" })
            }, resolveValues: { context in
                let settings = context.settings?.zoommate
                guard settings?.cookieSource != .off else { return nil }
                let capture = settings?.cookieSource == .manual ? Self.capture(settings?.manualCookieHeader) : nil
                var headers = capture?.headers ?? [:]
                let auth = headers.removeValue(forKey: "authorization")
                headers.removeValue(forKey: "cookie")
                let encoded = (try? JSONSerialization.data(withJSONObject: headers)) ?? Data("{}".utf8)
                return .init(
                    settings: ["HOST": capture?.host ?? ""],
                    secrets: [
                        "AUTHORIZATION": auth ?? "",
                        "HEADERS": String(data: encoded, encoding: .utf8) ?? "{}",
                    ])
            }, isEnabled: { _ in true })
    }
}
