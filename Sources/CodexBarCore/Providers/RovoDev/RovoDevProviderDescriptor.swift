import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum RovoDevProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .rovodev,
            metadata: ProviderMetadata(
                id: .rovodev,
                displayName: "Rovo Dev",
                sessionLabel: "Credits",
                weeklyLabel: "Monthly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Rovo Dev usage",
                cliName: "rovodev",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://www.atlassian.com/software/rovo-dev",
                subscriptionDashboardURL: nil,
                statusPageURL: nil,
                statusLinkURL: "https://status.atlassian.com"),
            branding: ProviderBranding(
                iconStyle: .rovodev,
                iconResourceName: "ProviderIcon-rovodev",
                color: ProviderColor(red: 0.0, green: 0.322, blue: 0.800)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Rovo Dev cost history is not available via API." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [RovoDevAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "rovodev",
                aliases: ["rovo-dev", "rovo"],
                versionDetector: nil))
    }
}

struct RovoDevAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "rovodev.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveCredentials(context: context) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let (email, apiToken) = Self.resolveCredentials(context: context) else {
            throw RovoDevUsageError.missingCredentials
        }
        let snapshot = try await RovoDevUsageFetcher.fetchUsage(
            email: email,
            apiToken: apiToken,
            environment: context.env)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    // MARK: - Credential resolution

    /// Resolves (email, apiToken) from environment variables or token accounts.
    ///
    /// Priority:
    /// 1. ROVODEV_API_TOKEN + ROVODEV_EMAIL environment variables
    /// 2. Token accounts (label = email, token = API token)
    private static func resolveCredentials(context: ProviderFetchContext) -> (String, String)? {
        // 1. Environment variables
        if let token = RovoDevSettingsReader.apiToken(environment: context.env),
           let email = RovoDevSettingsReader.email(environment: context.env)
        {
            return (email, token)
        }

        // 2. Token accounts (label stores email, token stores API key)
        if let account = context.tokenAccounts?.first(where: { !$0.token.isEmpty && !$0.label.isEmpty }) {
            return (account.label, account.token)
        }

        return nil
    }
}
