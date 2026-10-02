import Foundation

public enum LangdockProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        id: .langdock,
        settingsSection: .init(LangdockProviderSettingsKey.self, credentialSettings: { context in
            LangdockProviderSettings(edgeProfileID: context.config?.langdockEdgeProfileID)
        }),
        metadata: ProviderMetadata(
            id: .langdock,
            displayName: "Langdock",
            sessionLabel: "Session",
            weeklyLabel: "Weekly",
            opusLabel: nil,
            supportsOpus: false,
            supportsCredits: false,
            creditsHint: "",
            toggleTitle: "Show Langdock usage",
            cliName: "langdock",
            defaultEnabled: false,
            widgetSelectable: false,
            burnDownWidgetSelectable: false,
            isPrimaryProvider: false,
            usesAccountFallback: false,
            dashboardURL: "https://app.langdock.com/settings/account/usage",
            statusPageURL: nil),
        branding: ProviderBranding(
            iconStyle: .init(provider: .langdock),
            iconResourceName: "ProviderIcon-langdock",
            color: ProviderColor(red: 90 / 255, green: 74 / 255, blue: 231 / 255),
            confettiPalette: [ProviderColor(hex: 0x5A4AE7), ProviderColor(hex: 0xB3AAFF)]),
        tokenCost: ProviderTokenCostConfig(
            supportsTokenCost: false,
            noDataMessage: { "Langdock cost usage is not supported." }),
        history: .unavailable,
        fetchPlan: ProviderFetchPlan(
            sourceModes: [.auto, .web],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [LangdockWebFetchStrategy()] })),
        cli: ProviderCLIConfig(name: "langdock", versionDetector: nil))
}

struct LangdockWebFetchStrategy: ProviderFetchStrategy {
    let id = "langdock.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await LangdockUsageFetcher.fetch(
            edgeProfileID: context.settings?.langdock?.edgeProfileID,
            timeout: context.webTimeout)
        return self.makeResult(usage: snapshot, sourceLabel: "Edge")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
