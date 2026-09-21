import Foundation
import SweetCookieKit

public enum HelmcodeProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        nil
        #endif
    }

    public static func dashboardURL(snapshot: UsageSnapshot?) -> URL {
        let domain = snapshot?.identity?.accountOrganization == "NaN Builders" ? "nan.builders" : "helmcode.com"
        return URL(string: "https://cloud.\(domain)/dashboard")!
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .helmcode,
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
            credentials: ProviderCredentialAdapter(usesRegion: true),
            metadata: ProviderMetadata(
                id: .helmcode,
                displayName: "Helmcode",
                sessionLabel: "Model quota",
                weeklyLabel: "Model quota",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Helmcode usage",
                cliName: "helmcode",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://cloud.helmcode.com/dashboard",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .helmcode),
                iconResourceName: "ProviderIcon-helmcode",
                color: ProviderColor(hex: 0x4934E1),
                confettiPalette: [ProviderColor(hex: 0x4934E1), ProviderColor(hex: 0x8B7CF6)]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Helmcode per-request cost history is not available in CodexBar." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .prepaidCredits) },
                extraRateWindowSelector: { $0.extraRateWindows ?? [] },
                menuCard: ProviderMenuCardPresentation(showsPrimaryBalanceDescription: true),
                menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [ScriptFetchStrategy(
                        id: "helmcode.web",
                        provider: .helmcode,
                        bundledPlugin: "helmcode",
                        sourceLabel: "web",
                        kind: .web,
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
                        resolveValues: { context in
                            .init(settings: ["TENANT": context.settings?[HelmcodeProviderSettingsKey.self]?.manualTenant
                                    ?? "helmcode"])
                        },
                        isEnabled: { _ in true })]
                })),
            cli: ProviderCLIConfig(name: "helmcode", aliases: ["helm-code"], versionDetector: nil))
    }
}
