import Foundation

/// Direct API fetch strategy for Kiro usage that bypasses `kiro-cli` and calls
/// the AWS Q `getUsageLimits` REST endpoint directly.
///
/// This fixes enterprise/IdC account usage fetching where `kiro-cli` fails because
/// it incorrectly passes `profileArn` to the legacy REST API, causing a 400 error.
/// The Kiro 0.9.2 version of these APIs does NOT accept `profileArn`.
///
/// Reference: https://github.com/ZyphrZero/kiro.rs (v0.6.11 fix)
struct KiroAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "kiro.api"
    let kind: ProviderFetchKind = .apiToken

    private let fetcher: KiroAPIUsageFetcher

    init(fetcher: KiroAPIUsageFetcher = KiroAPIUsageFetcher()) {
        self.fetcher = fetcher
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        self.fetcher.hasCredentials(allowSocial: context.sourceMode == .api)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await self.fetcher.fetchUsage(allowSocial: context.sourceMode == .api)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }
}
