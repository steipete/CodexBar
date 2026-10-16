import Foundation

public enum KiroProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .kiro,
            metadata: ProviderMetadata(
                id: .kiro,
                displayName: "Kiro",
                sessionLabel: "Credits",
                weeklyLabel: "Bonus",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Kiro usage",
                cliName: "kiro",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Kiro debug log not yet implemented",
                dashboardURL: "https://app.kiro.dev/account/usage",
                statusPageURL: nil,
                statusLinkURL: "https://health.aws.amazon.com/health/status"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .kiro),
                iconResourceName: "ProviderIcon-kiro",
                color: ProviderColor(hex: 0x9046FF),
                confettiPalette: [
                    ProviderColor(hex: 0x9046FF),
                    ProviderColor(hex: 0xCAA9FF),
                    ProviderColor(hex: 0x2B2B2B),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Kiro cost summary is not supported." }),
            pace: .calendarMonthResetWindow,
            presentation: ProviderUsagePresentation(
                menuBarWindowResolver: { context in
                    guard context.metric == .automatic else { return .unhandled }
                    return .resolved(
                        ProviderUsagePresentation.exhausted(context.snapshot.primary, context.snapshot.secondary)
                            ?? context.snapshot.primary ?? context.snapshot.secondary)
                },
                menuCard: ProviderMenuCardPresentation(primaryDetailKind: .kiroCredits)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [KiroCLIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "kiro",
                aliases: ["kiro-cli"],
                versionDetector: { _ in KiroStatusProbe.detectVersion() }))
    }
}

struct KiroCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "kiro.cli"
    let kind: ProviderFetchKind = .cli

    private let connectivityGate: KiroConnectivityGate
    private let makeProbe: @Sendable () -> KiroStatusProbe

    init(
        connectivityGate: KiroConnectivityGate = KiroConnectivityGate(),
        makeProbe: @escaping @Sendable () -> KiroStatusProbe = { KiroStatusProbe() })
    {
        self.connectivityGate = connectivityGate
        self.makeProbe = makeProbe
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        TTYCommandRunner.which("kiro-cli") != nil
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Check the CLI's own usage service, not the independently hosted dashboard.
        // A failed session refresh can otherwise open sign-in tabs on every refresh tick.
        try await self.connectivityGate.ensureReachable()
        let snap = try await self.makeProbe().fetch()
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
