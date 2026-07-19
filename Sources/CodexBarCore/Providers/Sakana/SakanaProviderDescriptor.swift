import Foundation

public enum SakanaProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .sakana,
            metadata: ProviderMetadata(
                id: .sakana,
                displayName: "Sakana AI",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Sakana AI usage",
                cliName: "sakana",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://console.sakana.ai/billing",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .sakana,
                iconResourceName: "ProviderIcon-sakana",
                color: ProviderColor(red: 0.16, green: 0.46, blue: 0.86),
                confettiPalette: [
                    ProviderColor(hex: 0xE10600),
                    ProviderColor(hex: 0x0D0D0D),
                    ProviderColor(hex: 0xFFFFFF),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Sakana AI cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [SakanaWebFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "sakana",
                aliases: ["sakana-ai"],
                versionDetector: nil))
    }
}

struct SakanaWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "sakana.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        SakanaSettingsReader.cookieHeader(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let cookieHeader = SakanaSettingsReader.cookieHeader(environment: context.env) else {
            throw SakanaUsageError.missingCookie
        }
        let usage = try await SakanaUsageFetcher.fetchUsage(
            cookieHeader: cookieHeader,
            timeout: context.webTimeout,
            includeOptionalUsage: context.includeOptionalUsage)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
