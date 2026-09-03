import Foundation

public enum PiProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .pi,
            metadata: ProviderMetadata(
                id: .pi,
                displayName: "Pi",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Pi usage",
                cliName: "pi",
                defaultEnabled: false,
                widgetSelectable: true,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://github.com/badlogic/pi-mono",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .pi),
                iconResourceName: "ProviderIcon-pi",
                color: ProviderColor(hex: 0x7C3AED),
                confettiPalette: [
                    ProviderColor(hex: 0x7C3AED),
                    ProviderColor(hex: 0xA78BFA),
                    ProviderColor(hex: 0xEDE9FE),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: self.noDataMessage,
                menuHintLines: [.estimate],
                supportsTokenSnapshot: true,
                settingsStatusOrder: 10,
                showsHintInProviderDetails: true,
                historyTitleStyle: .compact,
                hintPlacement: .afterRequestHistory,
                chartEstimateDisclaimer: .localized("codex_api_estimate_hint")),
            pace: .unsupported,
            history: .alwaysTracked,
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(supportsInlineTokenCostDashboard: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [PiLocalFetchStrategy()] })),
            cli: ProviderCLIConfig(name: "pi", versionDetector: nil, supportsCostCommand: true))
    }

    private static func noDataMessage() -> String {
        "No Pi sessions found."
    }
}

struct PiLocalFetchStrategy: ProviderFetchStrategy {
    let id: String = "pi.local"
    let kind: ProviderFetchKind = .localProbe
    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ c: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date(),
            dataConfidence: .estimated)
        return self.makeResult(usage: snapshot, sourceLabel: "local")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
