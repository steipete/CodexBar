import Foundation

public enum QuotaFeedProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        id: .quotafeed,
        settingsSection: .init(QuotaFeedProviderSettingsKey.self, credentialSettings: { context in
            QuotaFeedProviderSettings(path: context.config?.quotaFeedPath)
        }),
        metadata: ProviderMetadata(
            id: .quotafeed,
            displayName: "Quota Feed",
            sessionLabel: "Quota",
            weeklyLabel: "Weekly",
            opusLabel: nil,
            supportsOpus: false,
            supportsCredits: false,
            creditsHint: "",
            toggleTitle: "Show local quota feed",
            cliName: "quotafeed",
            defaultEnabled: false,
            widgetSelectable: false,
            burnDownWidgetSelectable: false,
            usesAccountFallback: false,
            dashboardURL: nil,
            statusPageURL: nil),
        branding: ProviderBranding(
            iconStyle: .init(provider: .quotafeed),
            iconResourceName: "ProviderIcon-quotafeed",
            color: ProviderColor(hex: 0x64748B),
            confettiPalette: [ProviderColor(hex: 0x64748B), ProviderColor(hex: 0x94A3B8)]),
        tokenCost: ProviderTokenCostConfig(
            supportsTokenCost: false,
            noDataMessage: { "Quota Feed does not provide token cost history." }),
        presentation: ProviderUsagePresentation(menuBarBalanceDetailLabels: ["Remaining"]),
        fetchPlan: ProviderFetchPlan(
            sourceModes: [.auto, .cli],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [QuotaFeedFetchStrategy()] })),
        cli: ProviderCLIConfig(name: "quotafeed", versionDetector: nil))
}

struct QuotaFeedFetchStrategy: ProviderFetchStrategy {
    let id = "quotafeed.local"
    let kind: ProviderFetchKind = .localProbe
    var reader = QuotaFeedReader()

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        SettingsValue.cleaned(context.settings?[QuotaFeedProviderSettingsKey.self]?.path) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try Task.checkCancellation()
        let usage = try self.reader.fetch(path: context.settings?[QuotaFeedProviderSettingsKey.self]?.path)
        return self.makeResult(usage: usage, sourceLabel: "local file")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
}
