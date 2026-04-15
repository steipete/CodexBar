import Foundation

public enum OllamaCloudProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        id: .ollamaCloud,
        metadata: ProviderMetadata(
            id: .ollamaCloud,
            displayName: "Ollama Cloud",
            sessionLabel: "Models",
            weeklyLabel: "Cloud",
            opusLabel: nil,
            supportsOpus: false,
            supportsCredits: false,
            creditsHint: "",
            toggleTitle: "Show Ollama cloud models",
            cliName: "ollama-cloud",
            defaultEnabled: false,
            isPrimaryProvider: false,
            usesAccountFallback: false,
            browserCookieOrder: nil,
            dashboardURL: "https://ollama.com/dashboard",
            statusPageURL: nil,
            statusLinkURL: "https://ollama.com"),
        branding: ProviderBranding(
            iconStyle: .ollamaCloud,
            iconResourceName: "ProviderIcon-ollama",
            color: ProviderColor(red: 59 / 255, green: 130 / 255, blue: 246 / 255)),
        tokenCost: ProviderTokenCostConfig(
            supportsTokenCost: false,
            noDataMessage: { "Ollama cloud usage not tracked here." }),
        fetchPlan: ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [OllamaCloudFetchStrategy()]
            })),
        cli: ProviderCLIConfig(
            name: "ollama-cloud",
            versionDetector: nil))
}

struct OllamaCloudFetchStrategy: ProviderFetchStrategy {
    let id: String = "ollama-cloud.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "Cloud models — sign in at ollama.com"),
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            openRouterUsage: nil,
            cursorRequests: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .ollamaCloud,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))

        return ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "cloud-api",
            strategyID: self.id,
            strategyKind: self.kind)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
