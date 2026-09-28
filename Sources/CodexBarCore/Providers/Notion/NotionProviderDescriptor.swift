import Foundation

public enum NotionProviderDescriptor {
    /// Notion reports the rolling allowance as a `6h` window — session-shaped, but wider than the
    /// 5-hour ceiling the shared session-pace paths assume. Windows longer than this are not rolling
    /// allowances and must not be paced as one.
    public static let rollingWindowMaxMinutes = 6 * 60

    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .notion,
            settingsSection: .init(
                NotionProviderSettingsKey.self,
                cookieSettings: { settings in
                    CookieProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: Self.manualHeader(settings.manualCookieHeader))
                },
                credentialSettings: { context in
                    let settings = context.cookieSettings(for: .notion)
                    return NotionProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader,
                        workspaceID: context.config?.workspaceID)
                }),
            metadata: ProviderMetadata(
                id: .notion,
                displayName: "Notion AI",
                sessionLabel: "Rolling",
                weeklyLabel: "Monthly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Notion AI usage",
                cliName: "notion",
                defaultEnabled: false,
                // Not yet supported in widgets.
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: ["free": "Free", "plus": "Plus", "business": "Business", "enterprise": "Enterprise"],
                browserCookieOrder: BrowserCookieImportSupport.chromeOnly(
                    reason: "Avoid probing unrelated browser stores"),
                dashboardURL: "https://app.notion.com/",
                statusPageURL: nil,
                statusLinkURL: "https://status.notion.so/"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .notion),
                iconResourceName: "ProviderIcon-notion",
                // Notion's UI accent blue, not its near-black brand ink: the ink is
                // indistinguishable from the unfilled track in a usage gauge.
                color: ProviderColor(red: 51 / 255, green: 126 / 255, blue: 169 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x337EA9),
                    ProviderColor(hex: 0xE16259),
                    ProviderColor(hex: 0x37352F),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Notion AI cost summary is not supported." }),
            // The billing-period window renews on a calendar cycle, so pace has to measure the real
            // month ending at the reset rather than the 30-day sentinel the snapshot carries.
            pace: ProviderPaceCapability(
                resetWindowPace: .windowDuration(minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes),
                inferredMonthlyDuration: .windowDuration(
                    minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes),
                primary: .session(maximumMinutes: self.rollingWindowMaxMinutes),
                sessionPaceWindowRule: .custom { window, _ in
                    guard let minutes = window.windowMinutes else { return false }
                    return minutes <= Self.rollingWindowMaxMinutes
                }),
            presentation: ProviderUsagePresentation(
                semanticWindowResolver: { snapshot in
                    let rolling = snapshot.primary.flatMap { window -> RateWindow? in
                        guard !window.isSyntheticPlaceholder,
                              let minutes = window.windowMinutes,
                              minutes <= Self.rollingWindowMaxMinutes
                        else { return nil }
                        return window
                    }
                    let monthly = snapshot.secondary.flatMap { window -> RateWindow? in
                        guard !window.isSyntheticPlaceholder,
                              window.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes
                        else { return nil }
                        return window
                    }
                    return ProviderSemanticWindows(session: rolling, weekly: monthly)
                },
                menuBarLayoutSecondaryLabel: "Monthly"),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    [Self.webStrategy(timeout: context.webTimeout)]
                })),
            cli: ProviderCLIConfig(
                name: "notion",
                aliases: ["notion-ai", "notionai"],
                versionDetector: nil))
    }
}

extension NotionProviderDescriptor {
    static func manualHeader(_ raw: String?) -> String? {
        let fields = CurlCaptureParser.headerFields(from: raw ?? "")
        guard let header = CookieHeaderNormalizer.normalize(
            CurlCaptureParser.headerValue(named: "Cookie", in: fields) ?? raw) else { return nil }
        return CookieHeaderNormalizer.pairs(from: header).isEmpty ? "token_v2=\(header)" : header
    }

    public static func webStrategy(
        timeout: TimeInterval = 15,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) -> ScriptFetchStrategy
    {
        ScriptFetchStrategy(
            id: "notion.web",
            provider: .notion,
            bundledPlugin: "notion",
            sourceLabel: "web",
            kind: .web,
            transport: transport,
            timeout: max(30, timeout * 2),
            resolveValues: { context in
                let settings = context.settings?.notion
                guard settings?.cookieSource != .off else { return nil }
                let fields = settings?.cookieSource == .manual
                    ? CurlCaptureParser.headerFields(from: settings?.manualCookieHeader ?? "") : []
                let names = [
                    "accept",
                    "accept-language",
                    "notion-audit-log-platform",
                    "notion-client-version",
                    "referer",
                    "sec-fetch-dest",
                    "sec-fetch-mode",
                    "sec-fetch-site",
                    "user-agent",
                    "x-notion-active-user-header",
                ]
                let headers = CurlCaptureParser.forwardedHeaders(
                    from: fields, allowlist: Dictionary(uniqueKeysWithValues: names.map { ($0, $0) }))
                let encoded = (try? JSONSerialization.data(withJSONObject: headers)) ?? Data("{}".utf8)
                return .init(
                    settings: ["WORKSPACE_ID": settings?.workspaceID ?? ""],
                    secrets: ["HEADERS": String(data: encoded, encoding: .utf8) ?? "{}"])
            }, isEnabled: { _ in true })
    }
}
