import Foundation
import Testing
@testable import CodexBarCore

private enum APITokenStrategyTestError: Error {
    case missingCredentials
}

private struct APITokenStrategyStubClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw APITokenStrategyTestError.missingCredentials
    }

    func debugRawProbe(model _: String) async -> String {
        "stub"
    }

    func detectVersion() -> String? {
        nil
    }
}

struct APITokenFetchStrategyTests {
    @Test
    func `missing token is unavailable and preserves provider error`() async {
        let strategy = Self.makeStrategy()
        let context = Self.makeContext(environment: [:])

        #expect(await strategy.isAvailable(context) == false)
        await #expect(throws: APITokenStrategyTestError.missingCredentials) {
            try await strategy.fetch(context)
        }
    }

    @Test
    func `resolved token loads usage and stamps result metadata`() async throws {
        let strategy = Self.makeStrategy()
        let context = Self.makeContext(environment: ["TEST_API_KEY": "test-token"])

        #expect(await strategy.isAvailable(context))
        let result = try await strategy.fetch(context)

        #expect(result.strategyID == "test.api")
        #expect(result.strategyKind == .apiToken)
        #expect(result.sourceLabel == "test-source")
        #expect(result.usage.updatedAt == Date(timeIntervalSince1970: 42))
        #expect(strategy.shouldFallback(on: APITokenStrategyTestError.missingCredentials, context: context) == false)
    }

    private static func makeStrategy() -> APITokenFetchStrategy {
        APITokenFetchStrategy(
            id: "test.api",
            sourceLabel: "test-source",
            resolveToken: { $0["TEST_API_KEY"] },
            missingCredentialsError: { APITokenStrategyTestError.missingCredentials },
            loadUsage: { token, context in
                UsageSnapshot(
                    primary: nil,
                    secondary: nil,
                    updatedAt: token == context.env["TEST_API_KEY"]
                        ? Date(timeIntervalSince1970: 42)
                        : Date.distantFuture)
            })
    }

    private static func makeContext(environment: [String: String]) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: APITokenStrategyStubClaudeFetcher(),
            browserDetection: browserDetection)
    }
}
