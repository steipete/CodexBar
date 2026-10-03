import Foundation

public enum WorkBuddyProviderDescriptor {
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
        noDataMessage: "WorkBuddy credits are a monthly allowance, not a cost history.",
        menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic, .primary]),
        presentation: ProviderUsagePresentation(
            menuCard: ProviderMenuCardPresentation(
                showsPrimaryBalanceDescription: true,
                hidesPrimaryResetWithoutDate: true),
            menu: ProviderMenuDescriptorPresentation(
                primaryDescriptionIsDetail: { _ in true }),
            planRow: ProviderPlanRowPresentation(label: "Plan")),
        webSource: .init(
            settingsSection: .init(WorkBuddyProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: BrowserCookieImportSupport.chromeOnly(
                reason: "WorkBuddy imports only Chrome to avoid unrelated browser prompts."),
            timeout: .web(minimum: 30, maximum: .infinity, padding: 0, nonFinite: 30),
            browserSupportExemption: { _, _, settings in
                settings?.workbuddy?.cookieSource == .manual
            },
            resolveValues: { context in
                guard context.settings?.workbuddy?.cookieSource != .off else { return nil }
                var settings = ["webTimeoutSeconds": String(context.webTimeout)]
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
                    title: "Open WorkBuddy Usage",
                    url: "https://www.workbuddy.cn/profile/plans-usage")),
            picker: .init(
                id: "workbuddy-cookie-source",
                allowsOff: true,
                auto: .localized("Automatic imports Chrome cookies from www.workbuddy.cn."),
                manual: .localized("Paste a Cookie header captured from %@.", argument: "the plans and usage page"),
                off: .localized("%@ cookies are disabled.", argument: "WorkBuddy"),
                showsRefreshAction: true),
            detailLine: "web"))
}
