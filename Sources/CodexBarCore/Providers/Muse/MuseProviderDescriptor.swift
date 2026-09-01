import Foundation

public enum MuseProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .muse,
            metadata: ProviderMetadata(
                id: .muse,
                displayName: "Muse",
                sessionLabel: "Today",
                weeklyLabel: "30-day",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Muse usage",
                cliName: "muse",
                defaultEnabled: false,
                widgetSelectable: false,
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .muse),
                iconResourceName: "ProviderIcon-muse",
                color: ProviderColor(red: 114 / 255, green: 96 / 255, blue: 255 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x7260FF),
                    ProviderColor(hex: 0x1A1A1A),
                    ProviderColor(hex: 0xEDE8FF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: {
                    "No Muse sessions found in ~/.local/share/muse/sessions."
                },
                supportsTokenSnapshot: true,
                estimateDisclaimer: "From local Muse session logs; tokens only, no billing."),
            pace: .unsupported,
            history: .optIn,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MuseLocalFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "muse",
                versionDetector: { _ in ProviderVersionDetector.museVersion() }))
    }
}

struct MuseLocalFetchStrategy: ProviderFetchStrategy {
    let id: String = "muse.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_: ProviderFetchContext) async -> Bool { true }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let summary = try await MuseLocalSessionScanner.summarizeOffMainThread(
            env: context.env,
            lookbackDays: context.costUsageHistoryDays,
            now: Date())
        guard summary.toCostUsageTokenSnapshot(historyDays: context.costUsageHistoryDays) != nil else {
            throw MuseLocalError.noUsage
        }
        let snapshot = MuseUsageSnapshot(summary: summary, updatedAt: summary.scannedAt)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "local")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
}

private enum MuseLocalError: LocalizedError, Sendable {
    case noUsage
    var errorDescription: String? {
        "No Muse sessions found in ~/.local/share/muse/sessions."
    }
}
