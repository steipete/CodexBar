import Foundation

public enum ClaudePlatformProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .claudeplatform,
        displayName: "Claude Platform",
        sessionLabel: "API credit",
        weeklyLabel: "Purchased credit",
        usesDetailBackedWindow: true,
        dashboardURL: "https://platform.claude.com/settings/billing",
        statusPageURL: "https://status.claude.com/",
        color: ProviderColor(hex: 0xCC7C5E),
        confetti: [0xD97757, 0xF0EEE6, 0x141413],
        noDataMessage: "Claude Platform exposes Console credit balance and monthly spend, "
            + "not local token cost history.",
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in
                ProviderCostPresentation(showsGenericFallback: false, menuCardStyle: .prepaidCredits)
            },
            menuBarBalanceUsesPrepaidCost: true,
            menuBarWindowResolver: { context in
                guard context.metric == .automatic else { return .unhandled }
                return .resolved(context.snapshot.primary ?? context.snapshot.secondary)
            },
            // Credit grants expire rather than reset, so their expiry stays a detail line.
            menuCard: ProviderMenuCardPresentation(
                showsPrimaryBalanceDescription: true,
                showsSecondaryBalanceDescription: true,
                clearsPrimaryReset: true),
            menu: ProviderMenuDescriptorPresentation(
                primaryDescriptionIsDetail: { _ in true },
                secondaryDescriptionMode: .detailWhenResetDatePresent)),
        aliases: ["claude-platform"],
        webSource: .init(
            settingsSection: .init(
                ClaudePlatformProviderSettingsKey.self,
                cookieSettings: CookieProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            timeout: .fixed(60),
            browserSupportExemption: { _, _, settings in
                settings?[ClaudePlatformProviderSettingsKey.self]?.cookieSource == .manual
            },
            field: .init(
                id: "claudeplatform-cookie",
                title: "Cookie header",
                subtitle: "Paste a platform.claude.com Cookie header containing sessionKey.",
                placeholder: "Cookie: …",
                action: (
                    id: "claudeplatform-open-billing",
                    title: "Open Console",
                    url: "https://platform.claude.com/settings/billing")),
            picker: .init(
                id: "claudeplatform-cookie-source",
                allowsOff: true,
                auto: .localized("Automatically imports browser session cookie."),
                manual: .localized("Paste a Cookie header from %@.", argument: "platform.claude.com"),
                off: .localized("%@ cookies are disabled.", argument: "Claude Platform"),
                showsRefreshAction: true),
            detailLine: "web",
            showsVersionInSettings: false,
            loginURL: "https://platform.claude.com/"))
}

public enum ClaudePlatformProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.claudeplatform
    public typealias Section = CookieProviderSettings
}
