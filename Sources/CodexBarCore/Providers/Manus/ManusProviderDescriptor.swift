import Foundation

public enum ManusProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor(credentials: Self.credentials)
    public static let spec = PluginProviderSpec(
        id: .manus,
        displayName: "Manus",
        sessionLabel: "Monthly credits",
        weeklyLabel: "Daily refresh",
        debugLogUnavailableMessage: "Manus debug log not yet implemented",
        usesDetailBackedWindow: true,
        dashboardURL: "https://manus.im",
        color: .init(hex: 0x34322D),
        confetti: [0x34322D, 0xF2F0E9, 0x0099FF],
        widgetColor: .init(hex: 0x181818),
        noDataMessage: "Manus cost summary is not supported.",
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .hidden) },
            menuCard: ProviderMenuCardPresentation(
                showsPrimaryBalanceDescription: true,
                showsSecondaryBalanceDescription: true,
                clearsPrimaryReset: true),
            menu: ProviderMenuDescriptorPresentation(
                primaryDescriptionIsDetail: { _ in true },
                secondaryDescriptionMode: .detailWhenResetDatePresent)),
        webSource: .init(
            settingsSection: .init(ManusProviderSettingsKey.self, cookieSettings: ManusProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            resolveValues: { context in
                guard context.settings?.manus?.cookieSource != .off else { return nil }
                let token = ManusSettingsReader.sessionToken(environment: context.env)
                return .init(secrets: token.map { ["SESSION_TOKEN": $0] } ?? [:])
            },
            field: .init(
                id: "manus-cookie",
                title: "",
                subtitle: "",
                placeholder: "session_id=...\n\nor paste just the session_id value",
                action: (id: "manus-open-dashboard", title: "Open Manus", url: "https://manus.im")),
            picker: .init(
                id: "manus-cookie-source",
                allowsOff: true,
                auto: .localized("Automatically imports browser session cookies."),
                manual: .localized("Paste the %@ value or a full Cookie header.", argument: "session_id"),
                off: .localized("%@ cookies are disabled.", argument: "Manus")),
            detailLine: "web",
            loginURL: "https://manus.im"))

    private static let credentials = ProviderCredentialAdapter(
        tokenAccountSupport: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple Manus session_id cookies.",
            placeholder: "session_id=…",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: ManusCookieHeader.sessionCookieName),
        authDetector: { environment, _ in
            ManusSettingsReader.sessionToken(environment: environment) == nil ? [] : ["web"]
        })
}
