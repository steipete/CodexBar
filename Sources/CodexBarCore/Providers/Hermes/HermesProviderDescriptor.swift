import Foundation

public enum HermesProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .hermes,
            metadata: ProviderMetadata(
                id: .hermes,
                displayName: "Hermes",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Hermes usage",
                cliName: "hermes",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Hermes debug log not yet implemented",
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .hermes),
                iconResourceName: "ProviderIcon-hermes",
                color: ProviderColor(red: 123 / 255, green: 104 / 255, blue: 238 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x7B68EE),
                    ProviderColor(hex: 0x6A5ACD),
                    ProviderColor(hex: 0x483D8B),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: {
                    let home = HermesLocalReader.hermesHomeURL().path
                    return "No Hermes sessions found in \(home)/state.db. Run Hermes Agent to generate usage history."
                },
                supportsTokenSnapshot: true,
                showsHintInProviderDetails: true),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(
                    costVisibilityResolver: { $0.showOptionalUsage },
                    supportsInlineTokenCostDashboard: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "hermes",
                versionDetector: nil,
                supportsCostCommand: true))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        [HermesLocalFetchStrategy()]
    }
}

struct HermesLocalFetchStrategy: ProviderFetchStrategy {
    let id: String = "hermes.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        _ = context
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let localContext = HermesLocalReader.Context(environment: context.env)
        guard HermesLocalReader.hasLocalStore(context: localContext) else {
            let path = localContext.home.path
            throw HermesLocalError.noLocalData(path)
        }
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: nil)
        return self.makeResult(usage: snapshot, sourceLabel: "local")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        _ = error
        _ = context
        return false
    }
}

public enum HermesLocalError: LocalizedError, Equatable, Sendable {
    case noLocalData(String)

    public var errorDescription: String? {
        switch self {
        case let .noLocalData(path):
            "No Hermes sessions found in \(path)/state.db."
        }
    }
}
