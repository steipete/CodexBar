import Foundation

public enum RaycastProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .raycast,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic, .primary]),
            settingsSection: .init(RaycastProviderSettingsKey.self, cookieSettings: CookieProviderSettings.self),
            metadata: ProviderMetadata(
                id: .raycast,
                displayName: "Raycast",
                sessionLabel: "Credits",
                weeklyLabel: "Plan",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Raycast usage",
                cliName: "raycast",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                usesDetailBackedWindow: true,
                browserCookieOrder: BrowserCookieImportSupport.chromeOnly(
                    reason: "Raycast imports only Chrome to avoid unrelated browser prompts."),
                dashboardURL: "https://www.raycast.com/settings",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .raycast),
                iconResourceName: "ProviderIcon-raycast",
                color: ProviderColor(hex: 0xFF6363),
                confettiPalette: [
                    ProviderColor(hex: 0xFF6363),
                    ProviderColor(hex: 0xFF8C8C),
                    ProviderColor(hex: 0x1A1A1A),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Raycast AI credits are a monthly allowance, not a cost history." }),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true),
                menu: ProviderMenuDescriptorPresentation(
                    primaryDescriptionIsDetail: { _ in true }),
                planRow: ProviderPlanRowPresentation(label: "Plan")),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    [ScriptFetchStrategy(
                        id: "raycast.js",
                        provider: .raycast,
                        bundledPlugin: "raycast",
                        sourceLabel: "web",
                        kind: .web,
                        timeout: max(30, context.webTimeout.isFinite ? context.webTimeout : 30),
                        resolveValues: { context in
                            guard context.settings?.raycast?.cookieSource != .off else { return nil }
                            return .init(settings: ["webTimeoutSeconds": String(context.webTimeout)])
                        },
                        isEnabled: { _ in true })]
                })),
            cli: ProviderCLIConfig(
                name: "raycast",
                versionDetector: nil,
                browserSupportExemption: { _, _, settings in
                    settings?.raycast?.cookieSource == .manual
                }))
    }
}
