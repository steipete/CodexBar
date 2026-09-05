import Foundation

public enum SakanaProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(environmentProjections: [
        .cookieHeader(SakanaSettingsReader.cookieHeaderKey),
    ])

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .sakana,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .sakana,
                displayName: "Sakana AI",
                shortDisplayName: "Sakana",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Sakana AI usage",
                cliName: "sakana",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "standard": "Standard",
                    "standard $20/mo": "Standard",
                    "pro": "Pro",
                    "enterprise": "Enterprise",
                ],
                debugLogUnavailableMessage: "Sakana AI debug log not yet implemented",
                browserCookieOrder: nil,
                dashboardURL: "https://console.sakana.ai/billing",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .sakana),
                iconResourceName: "ProviderIcon-sakana",
                color: ProviderColor(red: 204 / 255, green: 43 / 255, blue: 43 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xCC2B2B),
                    ProviderColor(hex: 0x0D0D0D),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(red: 41 / 255, green: 117 / 255, blue: 219 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Sakana AI cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                optionalDetails: ProviderOptionalDetailsPresentation(hidesAllWithoutOptionalUsage: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [SakanaWebFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "sakana",
                aliases: ["sakana-ai"],
                versionDetector: nil,
                browserSupportExemption: { sourceMode, environment, _ in
                    guard sourceMode == .auto || sourceMode == .web else { return false }
                    return environment.map { SakanaSettingsReader.cookieHeader(environment: $0) != nil } == true
                }))
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
