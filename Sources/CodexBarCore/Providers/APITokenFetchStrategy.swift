import Foundation

public struct APITokenFetchStrategy: ProviderFetchStrategy {
    public typealias TokenResolver = @Sendable ([String: String]) -> String?
    public typealias MissingCredentialsError = @Sendable () -> (any Error & Sendable)
    public typealias UsageLoader = @Sendable (String, ProviderFetchContext) async throws -> UsageSnapshot

    public let id: String
    public let kind: ProviderFetchKind = .apiToken

    private let sourceLabel: String
    private let resolveToken: TokenResolver
    private let missingCredentialsError: MissingCredentialsError
    private let loadUsage: UsageLoader

    public init(
        id: String,
        sourceLabel: String = "api",
        resolveToken: @escaping TokenResolver,
        missingCredentialsError: @escaping MissingCredentialsError,
        loadUsage: @escaping UsageLoader)
    {
        self.id = id
        self.sourceLabel = sourceLabel
        self.resolveToken = resolveToken
        self.missingCredentialsError = missingCredentialsError
        self.loadUsage = loadUsage
    }

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        self.resolveToken(context.env) != nil
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let token = self.resolveToken(context.env) else {
            throw self.missingCredentialsError()
        }
        return try await self.makeResult(
            usage: self.loadUsage(token, context),
            sourceLabel: self.sourceLabel)
    }

    public func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

extension ProviderFetchPlan {
    public static func apiToken(
        strategyID: String,
        sourceLabel: String = "api",
        resolveToken: @escaping APITokenFetchStrategy.TokenResolver,
        missingCredentialsError: @escaping APITokenFetchStrategy.MissingCredentialsError,
        loadUsage: @escaping APITokenFetchStrategy.UsageLoader) -> ProviderFetchPlan
    {
        ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [APITokenFetchStrategy(
                    id: strategyID,
                    sourceLabel: sourceLabel,
                    resolveToken: resolveToken,
                    missingCredentialsError: missingCredentialsError,
                    loadUsage: loadUsage)]
            }))
    }
}
