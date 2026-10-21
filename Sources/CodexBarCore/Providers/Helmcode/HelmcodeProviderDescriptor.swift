import Foundation

public enum HelmcodeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec
        .makeDescriptor(credentials: ProviderCredentialAdapter(usesRegion: true))
    public static let spec = PluginProviderSpec(
        id: .helmcode,
        displayName: "Helmcode",
        sessionLabel: "Model quota",
        weeklyLabel: "Model quota",
        dashboardURL: "https://cloud.helmcode.com/dashboard",
        color: .init(hex: 0x4934E1),
        confetti: [0x4934E1, 0x8B7CF6],
        noDataMessage: "Helmcode per-request cost history is not available in CodexBar.",
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .prepaidCredits) },
            extraRateWindowSelector: { $0.extraRateWindows ?? [] },
            menuCard: ProviderMenuCardPresentation(showsPrimaryBalanceDescription: true),
            menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
        aliases: ["helm-code"],
        validateContext: { context in
            if context.settings?[HelmcodeProviderSettingsKey.self]?.cookieSource == .manual,
               context.settings?[HelmcodeProviderSettingsKey.self]?.manualCookieHeader?
                   .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                   .hasPrefix("curl ") == true
            {
                throw ProviderPluginError
                    .secretAccess("Paste a Cookie header instead of a cURL capture.")
            }
        },
        webSource: .init(
            settingsSection: .init(
                HelmcodeProviderSettingsKey.self,
                cookieSettings: { .init(cookieSource: $0.cookieSource, manualCookieHeader: $0.manualCookieHeader) },
                credentialSettings: { context in
                    let cookies = context.cookieSettings(for: .helmcode)
                    return HelmcodeProviderSettings(
                        cookieSource: cookies.cookieSource,
                        manualCookieHeader: cookies.manualCookieHeader,
                        manualTenant: context.config?.sanitizedRegion)
                }),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            strategySuffix: .web,
            resolveValues: { context in
                .init(settings: ["TENANT": context.settings?[HelmcodeProviderSettingsKey.self]?.manualTenant
                        ?? "helmcode"])
            },
            field: .init(
                id: "helmcode-cookie",
                title: "Cookie header",
                subtitle: "Copy the Cookie request header from your tenant's dashboard. " +
                    "cURL captures are not supported.",
                placeholder: "Cookie: …"),
            picker: .init(
                id: "helmcode-cookie-source",
                allowsOff: true,
                auto: .literal("Imports browser sessions for Helmcode Cloud or NaN Builders; Cloud is preferred."),
                manual: .literal("Paste a Cookie header and select its tenant below."),
                off: .literal("Helmcode dashboard cookies are disabled."))))

    public static func dashboardURL(snapshot: UsageSnapshot?) -> URL {
        let domain = snapshot?.identity?.accountOrganization == "NaN Builders" ? "nan.builders" : "helmcode.com"
        return URL(string: "https://cloud.\(domain)/dashboard")!
    }
}
