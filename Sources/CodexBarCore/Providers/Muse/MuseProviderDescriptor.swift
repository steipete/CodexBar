import Foundation

public enum MuseProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: MuseSettingsReader.apiKeyEnvironmentKey,
        resolve: { MuseSettingsReader.apiKey(environment: $0) })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .muse,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .muse,
                displayName: "Meta Muse",
                shortDisplayName: "Muse",
                sessionLabel: "Today",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Meta Muse usage",
                cliName: "muse",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Muse debug log not yet implemented",
                browserCookieOrder: nil,
                dashboardURL: "https://developer.meta.com/ai",
                subscriptionDashboardURL: "https://developer.meta.com/ai",
                changelogURL: "https://developer.meta.com/ai/resources/blog/muse-code-new-plans-and-features/",
                statusPageURL: nil,
                statusLinkURL: "https://developer.meta.com/ai"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .muse),
                iconResourceName: "ProviderIcon-muse",
                color: ProviderColor(red: 0 / 255, green: 100 / 255, blue: 224 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x0064E0),
                    ProviderColor(hex: 0x00A3FF),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(red: 0 / 255, green: 100 / 255, blue: 224 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No Muse sessions or token usage found." },
                menuHintLines: [.literal("Estimated from local Muse session logs.")],
                supportsTokenSnapshot: true),
            presentation: ProviderUsagePresentation(
                identityPresenter: { provider, snapshot in
                    // The login line carries local token totals, not a plan; keep the tier as the plan and
                    // show the totals verbatim instead of title-casing them.
                    let plan = snapshot.accountOrganization(for: provider)
                        .flatMap { $0.isEmpty ? nil : UsageFormatter.cleanPlanName($0) }
                    let totals = snapshot.loginMethod(for: provider).flatMap { $0.isEmpty ? nil : $0 }
                    return ProviderIdentityPresentation(
                        badge: plan,
                        plan: plan,
                        details: totals.map { [.init(label: "Tokens", value: $0)] } ?? [])
                },
                menuCard: ProviderMenuCardPresentation(supportsInlineTokenCostDashboard: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MuseFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "muse",
                aliases: ["muse-code", "meta-muse"],
                versionDetector: { _ in MuseStatusProbe.detectCLIVersion() },
                supportsCostCommand: true))
    }
}

public struct MuseFetchStrategy: ProviderFetchStrategy {
    public let id = "muse.local"
    public let kind = ProviderFetchKind.localProbe

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        let probe = MuseStatusProbe.probe(environment: context.env)
        return probe.hasSessions || probe.hasConfig || probe.isInstalled
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let usage = try await MuseUsageFetcher.fetchUsage(environment: context.env)
        return self.makeResult(usage: usage, sourceLabel: "local")
    }

    public func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
