import Foundation

public enum WorkBuddyProviderDescriptor {
    /// Sessions bind to the browser User-Agent; the host can reconstruct only Chrome's versioned User-Agent.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    private static let webTimeout = PluginProviderSpec.WebSource.Timeout.web(
        minimum: 30, maximum: .infinity, padding: 0, nonFinite: 30)
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .workbuddy,
        displayName: "WorkBuddy",
        sessionLabel: "Credits",
        weeklyLabel: "Plan",
        usesDetailBackedWindow: true,
        dashboardURL: "https://www.workbuddy.cn/profile/plans-usage",
        color: .init(hex: 0x0DC8A6),
        confetti: [0x0DC8A6, 0x7BE8D3, 0x1A1A1A],
        noDataMessage: "No cost history data.",
        menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic, .primary]),
        presentation: ProviderUsagePresentation(
            // Plugin snapshots default to no extra windows; the reward bucket is worth its own row.
            extraRateWindowSelector: { $0.extraRateWindows ?? [] },
            menuCard: ProviderMenuCardPresentation(
                showsPrimaryBalanceDescription: true,
                hidesPrimaryResetWithoutDate: true,
                // Reward credits lapse instead of resetting, so the window carries the balance
                // rather than a countdown the API cannot supply.
                extraRateWindowUsesResetDescriptionAsDetail: { $0.id == "rewards" }),
            menu: ProviderMenuDescriptorPresentation(
                primaryDescriptionIsDetail: { _ in true }),
            planRow: ProviderPlanRowPresentation(label: "Plan")),
        webSource: .init(
            settingsSection: .init(WorkBuddyProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: Self.browserCookieOrder,
            timeout: Self.webTimeout,
            browserSupportExemption: { _, _, settings in
                settings?.workbuddy?.cookieSource == .manual
            },
            resolveValues: { context in
                guard context.settings?.workbuddy?.cookieSource != .off else { return nil }
                var settings = [
                    "webTimeoutSeconds": String(context.webTimeout),
                    "resetDeadlineMillis": String(Date().addingTimeInterval(Self.webTimeout.resolve(context) - 1)
                        .timeIntervalSince1970 * 1000),
                ]
                if let major = WorkBuddyChromeVersion.majorVersion() {
                    settings["chromeMajorVersion"] = String(major)
                }
                return .init(settings: settings)
            },
            field: .init(
                id: "workbuddy-cookie-header",
                title: "Cookie header",
                subtitle: "Paste the Cookie header from a Chrome request to www.workbuddy.cn/profile/plans-usage.",
                placeholder: "Cookie: …",
                action: (
                    id: "workbuddy-open-usage",
                    title: "Open Usage Page",
                    url: "https://www.workbuddy.cn/profile/plans-usage")),
            picker: .init(
                id: "workbuddy-cookie-source",
                allowsOff: true,
                auto: .localized("Automatic imports browser cookies."),
                manual: .localized(
                    "Paste a Cookie header captured from %@.",
                    argument: "www.workbuddy.cn/profile/plans-usage"),
                off: .localized("%@ cookies are disabled.", argument: "WorkBuddy"),
                showsRefreshAction: true),
            detailLine: "web"))
}
