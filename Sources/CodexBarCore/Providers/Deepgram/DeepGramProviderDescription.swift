import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum DeepGramProviderDescriptor {
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
                dashboardURL: "https://console.deepgram.com/project/",
                statusPageURL: nil,
                statusLinkURL: "https://status.deepgram.com/"
            ),
            branding: ProviderBranding(
                iconStyle: .deepgram,
                iconResourceName: "ProviderIcon-deepgram",
                color: ProviderColor(
                    red: 100 / 255,
                    green: 103 / 255,
                    blue: 242 / 255
                )
            ),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: {
                    "Deepgram cost summary is not yet supported."
                }
            ),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(
                    resolveStrategies: { _ in
                        [DeepGramAPIFetchStrategy()]
                    }
                )
            ),
            cli: ProviderCLIConfig(
                name: "deepgram",
                aliases: ["dg"],
                versionDetector: nil
            )
        )
    }
}

struct DeepGramAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "deepgram.api"
    let kind: ProviderFetchKind = .apiToken

    let apiToken: String? = nil
    let projectID: String? = nil

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        resolveAPIKey(context) != nil &&
        resolveProjectID(context) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = resolveAPIKey(context) else {
            throw DeepGramSettingsError.missingToken
        }

        guard let projectID = resolveProjectID(context) else {
            throw DeepGramSettingsError.missingProjectID
        }

        let usage = try await DeepgramUsageFetcher.fetchUsage(
            apiKey: apiKey,
            projectID: projectID,
            environment: context.env
        )

        return makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api"
        )
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private func resolveAPIKey(_ context: ProviderFetchContext) -> String? {
        if let apiToken = cleaned(apiToken) {
            return apiToken
        }

        return ProviderTokenResolver.deepGramResolution(
            type: .apiKey,
            environment: context.env
        )
    }

    private func resolveProjectID(_ context: ProviderFetchContext) -> String? {
        if let projectID = cleaned(projectID) {
            return projectID
        }

        return ProviderTokenResolver.deepGramResolution(
            type: .projectID,
            environment: context.env
        )
    }

    private func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }

        return value
    }
}

/// Errors related to Deepgrarm settings
public enum DeepGramSettingsError: LocalizedError, Sendable {
    case missingToken
    case missingProjectID

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Deepgram API token not configured. Set DEEPGRAM_API_KEY environment variable or configure in Settings."
        case .missingProjectID:
        "Deepgram project ID not configured. Set DEEPGRAM_PROJECT_ID environment variable or configure in Settings."
        }
    }
}

