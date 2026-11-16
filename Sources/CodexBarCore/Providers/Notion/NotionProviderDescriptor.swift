import Foundation

public enum NotionProviderDescriptor {
    /// Notion reports the rolling allowance as a `6h` window — session-shaped, but wider than the
    /// 5-hour ceiling the shared session-pace paths assume. Windows longer than this are not rolling
    /// allowances and must not be paced as one.
    public static let rollingWindowMaxMinutes = 6 * 60

    private static func isPersonalAllowance(_ window: RateWindow?) -> Bool {
        window?.title == "Standard" || window?.title == "Select"
    }

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
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://app.notion.com/",
                statusPageURL: nil,
                statusLinkURL: "https://status.notion.so/"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .notion),
                iconResourceName: "ProviderIcon-notion",
                // Notion's UI accent blue, not its near-black brand ink: the ink is
                // indistinguishable from the unfilled track in a usage gauge.
                color: ProviderColor(hex: 0x337EA9),
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
                resetWindowPace: .custom { window, _ in
                    if Self.isPersonalAllowance(window) {
                        return window.windowMinutes != nil && window.resetsAt != nil
                    }
                    return window.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes
                },
                inferredMonthlyDuration: .custom { window in
                    !Self.isPersonalAllowance(window)
                        && window.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes
                },
                primary: .init(kind: .session, windowRule: .custom { window, _ in
                    guard !Self.isPersonalAllowance(window) else { return false }
                    return window.windowMinutes.map { $0 <= Self.rollingWindowMaxMinutes } ?? true
                }),
                sessionPaceWindowRule: .custom { window, _ in
                    guard !Self.isPersonalAllowance(window), let minutes = window.windowMinutes else { return false }
                    return minutes <= Self.rollingWindowMaxMinutes
                }),
            presentation: ProviderUsagePresentation(
                rateWindowLabeler: { metadata, snapshot, _ in
                    let personal = Self.isPersonalAllowance(snapshot.primary) || Self
                        .isPersonalAllowance(snapshot.secondary)
                    return ProviderRateWindowLabels(
                        primary: personal ? "Standard" : metadata.sessionLabel,
                        secondary: personal ? "Select" : metadata.weeklyLabel,
                        tertiary: metadata.opusLabel ?? "Sonnet",
                        showsTertiary: metadata.supportsOpus)
                },
                iconWindowResolver: { context in
                    let snapshot = context.snapshot
                    guard Self.isPersonalAllowance(snapshot.primary) || Self.isPersonalAllowance(snapshot.secondary)
                    else {
                        return ProviderUsageWindowPair(primary: snapshot.primary, secondary: snapshot.secondary)
                    }
                    return ProviderUsageWindowPair(
                        primary: snapshot.primary ?? snapshot.secondary,
                        secondary: snapshot.primary == nil ? nil : snapshot.secondary)
                },
                semanticWindowResolver: { snapshot in
                    if Self.isPersonalAllowance(snapshot.primary) || Self.isPersonalAllowance(snapshot.secondary) {
                        return ProviderSemanticWindows(session: nil, weekly: snapshot.primary ?? snapshot.secondary)
                    }
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
                // Semantic session tokens remain the legacy Rolling window; personal pools use named lanes.
                menuBarLayoutPrimaryLabel: "Rolling",
                menuBarLayoutSecondaryLabel: "Monthly",
                menuBarBalanceDetailLabels: ["Remaining credits"],
                legacyMenuBarShowsBalance: false,
                optionalDetails: ProviderOptionalDetailsPresentation(
                    hiddenTitlesWithoutOptionalUsage: ["Notion Credits"])),
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
            // Preserve the required-request budget, then reserve the three-second premium lookup
            // plus two seconds for scheduling and snapshot delivery. Other providers keep their budgets.
            timeout: max(30, timeout * 2) + 5,
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
                    settings: [
                        "WORKSPACE_ID": settings?.workspaceID ?? "",
                        "OPTIONAL_USAGE": String(context.includeOptionalUsage),
                    ],
                    secrets: ["HEADERS": String(data: encoded, encoding: .utf8) ?? "{}"])
            }, isEnabled: { _ in true })
    }
}
