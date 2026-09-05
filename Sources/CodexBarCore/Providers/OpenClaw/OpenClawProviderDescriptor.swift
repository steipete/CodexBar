import Foundation

public enum OpenClawProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .openclaw,
            metadata: ProviderMetadata(
                id: .openclaw,
                displayName: "OpenClaw",
                shortDisplayName: "OpenClaw",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenClaw usage",
                cliName: "openclaw",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "OpenClaw debug log not yet implemented",
                dashboardURL: nil,
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .openclaw),
                iconResourceName: "ProviderIcon-openclaw",
                color: ProviderColor(red: 239.0 / 255.0, green: 68.0 / 255.0, blue: 68.0 / 255.0),
                confettiPalette: [
                    ProviderColor(hex: 0xEF4444),
                    ProviderColor(hex: 0xF87171),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: {
                    "No OpenClaw usage returned. Start its Gateway and run a session, then try again."
                },
                supportsTokenSnapshot: true,
                estimateDisclaimer: "Estimated by OpenClaw from session usage; may differ from your bill",
                showsRequestHistory: false),
            presentation: ProviderUsagePresentation(),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "openclaw",
                aliases: ["claw", "open-claw"],
                binaryLocator: { BinaryLocator.resolveOpenClawBinary() },
                versionDetector: nil,
                supportsCostCommand: true,
                prefersBinaryLocatorForWhich: true))
    }

    private static func resolveStrategies(context _: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        [OpenClawCLIFetchStrategy()]
    }
}

struct OpenClawCLIFetchStrategy: ProviderFetchStrategy {
    let id = "openclaw.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        BinaryLocator.resolveOpenClawBinary(
            env: context.env,
            loginPATH: LoginShellPathCache.shared.current) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard BinaryLocator.resolveOpenClawBinary(
            env: context.env,
            loginPATH: LoginShellPathCache.shared.current) != nil
        else {
            throw SubprocessRunnerError.binaryNotFound("openclaw")
        }
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, tertiary: nil, updatedAt: Date(), identity: nil)
        return self.makeResult(usage: snapshot, sourceLabel: "gateway")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
