import Foundation

public enum GeminiProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .gemini,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(
                supported: [.automatic, .primary, .secondary, .average]),
            metadata: ProviderMetadata(
                id: .gemini,
                displayName: "Gemini",
                sessionLabel: "Pro",
                weeklyLabel: "Flash",
                opusLabel: "Flash Lite",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Gemini usage",
                cliName: "gemini",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "free": "Free", "paid": "Paid", "plus": "Plus", "workspace": "Workspace",
                    "legacy": "Legacy", "gemini code assist in google one ai pro": "Google One AI Pro",
                ],
                debugLogUnavailableMessage: "Gemini debug log not yet implemented",
                debugPane: ProviderDebugPaneCapabilities(errorSimulationOrder: 2),
                dashboardURL: "https://gemini.google.com",
                changelogURL: "https://github.com/google-gemini/gemini-cli/releases",
                statusPageURL: nil,
                statusLinkURL: "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history",
                statusWorkspaceProductID: "npdyhgECDJ6tB66MxXyo"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .gemini),
                iconResourceName: "ProviderIcon-gemini",
                color: ProviderColor(red: 171 / 255, green: 135 / 255, blue: 234 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x4285F4),
                    ProviderColor(hex: 0xA142F4),
                    ProviderColor(hex: 0xD96570),
                ],
                burnDownWidgetColor: ProviderColor(red: 0.420, green: 0.440, blue: 0.900)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Gemini cost summary is not supported." },
                supportsTokenSnapshot: true),
            presentation: ProviderUsagePresentation(
                identityPresenter: { provider, snapshot in
                    guard let plan = snapshot.loginMethod(for: provider), !plan.isEmpty else {
                        return ProviderIdentityPresentation(badge: nil, plan: nil)
                    }
                    let display = UsageFormatter.cleanPlanName(plan)
                    return ProviderIdentityPresentation(badge: display, plan: display)
                },
                iconDecorations: [.gemini]),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [GeminiStatusFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "gemini",
                binaryLocator: { BinaryLocator.resolveGeminiBinary() },
                versionDetector: { _ in ProviderVersionDetector.geminiVersion() },
                supportsCostCommand: true))
    }
}

struct GeminiStatusFetchStrategy: ProviderFetchStrategy {
    static let sourceLabel = "oauth-api"

    let id: String = "gemini.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = GeminiStatusProbe()
        let snap = try await probe.fetch()
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: Self.sourceLabel)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
