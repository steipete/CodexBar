import Foundation

struct MistralBudgetFetchStrategy: ProviderFetchStrategy {
    static let environmentKey = "MISTRAL_API_KEY"
    let id = "mistral.api"
    let kind: ProviderFetchKind = .apiToken
    var transport: any ProviderHTTPTransport = ProviderHTTPClient.shared

    static func apiKey(in env: [String: String]) -> String? {
        let key = env[self.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.sourceMode == .api || Self.apiKey(in: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let key = Self.apiKey(in: context.env) else { throw MistralBudgetError.missingKey }
        let budgets = try await MistralUsageFetcher.fetchBudget(
            apiKey: key,
            timeout: min(context.webTimeout, 4),
            transport: self.transport)
        let usage = MistralWebFetchStrategy.attachSubscriptionBudgets(
            to: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            budgets: budgets)
        return self.makeResult(usage: usage, sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}

enum MistralBudgetError: LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case rejectedKey
    case noBudget
    case network
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Set a Mistral API key in Settings or through MISTRAL_API_KEY."
        case .invalidKey: "The Mistral API key is malformed. Check the key in Settings."
        case .rejectedKey:
            "Mistral rejected the API key. Check its access or replace it in Settings, "
                + "or choose Browser cookies as the usage source."
        case .noBudget:
            "Mistral's billing API did not return usable allowances. "
                + "Choose Browser cookies as the usage source for spend, credits, and token history."
        case .network:
            "Could not reach the Mistral billing API. Retry the refresh, or choose Browser cookies "
                + "as the usage source."
        case let .http(status):
            "Mistral billing budget request failed (HTTP \(status)). "
                + "Choose Browser cookies as the usage source for spend, credits, and token history."
        }
    }
}
