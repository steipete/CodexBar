import Foundation

public enum DeepgramProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .deepgram,
            metadata: ProviderMetadata(
                id: .deepgram,
                displayName: "Deepgram",
                sessionLabel: "Requests",
                weeklyLabel: "Usage",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Usage summary from Deepgram API",
                toggleTitle: "Show Deepgram usage",
                cliName: "deepgram",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://console.deepgram.com/project/",
                statusPageURL: nil,
                statusLinkURL: "https://status.deepgram.com"),
            branding: ProviderBranding(
                iconStyle: .deepgram,
                iconResourceName: "ProviderIcon-deepgram",
                color: ProviderColor(
                    red: 100 / 255,
                    green: 103 / 255,
                    blue: 242 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x13EF95),
                    ProviderColor(hex: 0x149AFB),
                    ProviderColor(hex: 0x1A1A1F),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: {
                    "Deepgram cost summary is not yet supported."
                }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(
                    resolveStrategies: { _ in
                        [DeepgramAPIFetchStrategy()]
                    })),
            cli: ProviderCLIConfig(
                name: "deepgram",
                aliases: ["dg"],
                versionDetector: nil))
    }
}

struct DeepgramAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "deepgram.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveAPIKey(context) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveAPIKey(context) else {
            throw DeepgramSettingsError.missingToken
        }

        let usage = try await DeepgramUsageFetcher.fetchUsage(
            apiKey: apiKey,
            projectID: Self.resolveProjectID(context),
            environment: context.env)

        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveAPIKey(_ context: ProviderFetchContext) -> String? {
        ProviderTokenResolver.deepgramResolution(
            type: .apiKey,
            environment: context.env)
    }

    private static func resolveProjectID(_ context: ProviderFetchContext) -> String? {
        ProviderTokenResolver.deepgramResolution(
            type: .projectID,
            environment: context.env)
    }
}

/// Errors related to Deepgram settings
public enum DeepgramSettingsError: LocalizedError, Sendable {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Deepgram API token not configured. Set DEEPGRAM_API_KEY environment variable or configure in Settings."
        }
    }
}
