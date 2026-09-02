import Foundation

public enum CodeRabbitProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .coderabbit,
            metadata: ProviderMetadata(
                id: .coderabbit,
                displayName: "CodeRabbit",
                sessionLabel: "Reviews",
                weeklyLabel: "Billing",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Review count and billing period from CodeRabbit.",
                toggleTitle: "Show CodeRabbit usage",
                cliName: "coderabbit",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                balanceOnly: true,
                dashboardURL: "https://app.coderabbit.ai",
                statusPageURL: nil,
                statusLinkURL: "https://status.coderabbit.ai"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .coderabbit),
                iconResourceName: "ProviderIcon-coderabbit",
                color: ProviderColor(red: 255 / 255, green: 92 / 255, blue: 53 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xFF5C35),
                    ProviderColor(hex: 0xFFA07A),
                    ProviderColor(hex: 0x1A1A24),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "CodeRabbit cost summary is not supported." }),
            pace: .calendarMonthResetWindow,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "coderabbit",
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .auto, .cli:
            [CodeRabbitCLIFetchStrategy()]
        case .api, .web, .oauth:
            []
        }
    }
}

struct CodeRabbitCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "coderabbit.cli"
    let kind: ProviderFetchKind = .cli

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        BinaryLocator.resolveCoderabbitBinary(
            env: context.env,
            loginPATH: LoginShellPathCache.shared.current) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await CodeRabbitCLIProbe().fetch(environment: context.env)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(now: snapshot.updatedAt),
            sourceLabel: "cli")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return false
        }
        return context.sourceMode == .auto
    }
}
