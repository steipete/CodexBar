import Foundation

public enum DoubaoProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .doubao,
            metadata: ProviderMetadata(
                id: .doubao,
                displayName: "Doubao",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: "Monthly",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Doubao usage",
                cliName: "doubao",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?LLM=%7B%7D&advancedActiveKey=subscribe",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .doubao,
                iconResourceName: "ProviderIcon-doubao",
                color: ProviderColor(red: 51 / 255, green: 112 / 255, blue: 255 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Doubao cost summary is not available." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [DoubaoAPIFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "doubao",
                aliases: ["volcengine", "ark", "bytedance"],
                versionDetector: nil))
    }
}

struct DoubaoAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "doubao.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        DoubaoSettingsReader.codingPlanCredentials(environment: context.env) != nil ||
            ProviderTokenResolver.doubaoToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        if let credentials = DoubaoSettingsReader.codingPlanCredentials(environment: context.env) {
            let usage = try await DoubaoUsageFetcher.fetchCodingPlanUsage(credentials: credentials)
            return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
        }

        guard let apiKey = ProviderTokenResolver.doubaoToken(environment: context.env) else {
            throw DoubaoUsageError.missingCredentials
        }
        let usage = try await DoubaoUsageFetcher.fetchUsage(apiKey: apiKey)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
