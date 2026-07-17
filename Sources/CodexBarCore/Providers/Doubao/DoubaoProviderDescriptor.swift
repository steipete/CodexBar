import Foundation

public enum DoubaoProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    public static func primaryLabel(window: RateWindow?) -> String? {
        guard window?.windowMinutes == nil,
              window?.resetDescription?.localizedCaseInsensitiveContains("request") == true
        else {
            return nil
        }
        return "Requests"
    }

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
                color: ProviderColor(red: 51 / 255, green: 112 / 255, blue: 255 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x0057FF),
                    ProviderColor(hex: 0xEFC5BA),
                    ProviderColor(hex: 0x493530),
                ]),
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
    private let codingPlanUsageLoader: @Sendable (DoubaoCodingPlanCredentials) async throws -> DoubaoUsageSnapshot
    private let arkUsageLoader: @Sendable (String) async throws -> DoubaoUsageSnapshot

    init(
        codingPlanUsageLoader: @escaping @Sendable (DoubaoCodingPlanCredentials) async throws
            -> DoubaoUsageSnapshot = { credentials in
                try await DoubaoUsageFetcher.fetchCodingPlanUsage(credentials: credentials)
            },
        arkUsageLoader: @escaping @Sendable (String) async throws -> DoubaoUsageSnapshot = { apiKey in
            try await DoubaoUsageFetcher.fetchUsage(apiKey: apiKey)
        })
    {
        self.codingPlanUsageLoader = codingPlanUsageLoader
        self.arkUsageLoader = arkUsageLoader
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        DoubaoSettingsReader.codingPlanCredentials(environment: context.env) != nil ||
            ProviderTokenResolver.doubaoToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let apiKey = ProviderTokenResolver.doubaoToken(environment: context.env)
        if let credentials = DoubaoSettingsReader.codingPlanCredentials(environment: context.env) {
            do {
                let usage = try await self.codingPlanUsageLoader(credentials)
                return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
            } catch {
                if Self.isCancellation(error) {
                    throw error
                }
                guard let apiKey else {
                    throw error
                }
                let usage = try await self.arkUsageLoader(apiKey)
                return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
            }
        }

        guard let apiKey else {
            throw DoubaoUsageError.missingCredentials
        }
        let usage = try await self.arkUsageLoader(apiKey)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }
}
