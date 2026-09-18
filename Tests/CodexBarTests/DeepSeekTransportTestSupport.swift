import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

enum DeepSeekTransportTestSupport {
    static let candidateA = candidate("chrome:A", token: "synthetic-platform-token-A")
    static let candidateB = candidate("chrome:B", token: "synthetic-platform-token-B")

    static func candidate(_ id: String, token: String) -> DeepSeekPlatformTokenImporter.TokenInfo {
        .init(id: id, token: token, sourceLabel: id)
    }

    static func balance(_ amount: Double = 8.06) -> DeepSeekUsageSnapshot {
        DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "USD",
            totalBalance: amount,
            grantedBalance: 0,
            toppedUpBalance: amount,
            detailedUsageState: .notRequested,
            updatedAt: ProviderTransportRegressionSupport.capturedAt)
    }

    static func context(includeOptionalUsage: Bool = false) -> ProviderFetchContext {
        let browser = ProviderTransportRegressionSupport.browser(root: ProviderTransportRegressionFixtures.root)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .web,
            includeCredits: false,
            includeOptionalUsage: includeOptionalUsage,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser, environment: [:]),
            browserDetection: browser)
    }

    static func project(_ resolution: DeepSeekPlatformTokenImporter.Resolution) async throws -> UsageSnapshot {
        try await DeepSeekProviderDescriptor._loadPlatformUsageForTesting(
            context: self.context(),
            operations: .init(
                fetchUsage: { _, _, _ in Self.balance() },
                resolveAutomaticSession: { _, _, _, _, _, _ in resolution }))
    }

    static func successfulResolution(
        candidate: DeepSeekPlatformTokenImporter.TokenInfo,
        cache: DeepSeekPlatformValidationCache,
        selectedProfileID: String? = nil) async -> DeepSeekPlatformTokenImporter.Resolution
    {
        await DeepSeekPlatformTokenImporter._resolvePlatformBalanceForTesting(
            candidates: [candidate],
            selectedProfileID: selectedProfileID,
            cache: cache,
            validate: { _ in Self.balance() })
    }

    static func failedResolution(
        candidates: [DeepSeekPlatformTokenImporter.TokenInfo],
        selectedProfileID: String? = nil,
        requiresExplicitSelection: Bool = false,
        cache: DeepSeekPlatformValidationCache,
        error: Error = ProviderTransportRegressionSupport.urlError()) async
        -> DeepSeekPlatformTokenImporter.Resolution
    {
        await DeepSeekPlatformTokenImporter._resolvePlatformBalanceForTesting(
            candidates: candidates,
            selectedProfileID: selectedProfileID,
            requiresExplicitSelection: requiresExplicitSelection,
            cache: cache,
            validate: { _ in
                try await DeepSeekUsageFetcher._fetchPlatformUsageForTesting(
                    includeOptionalUsage: false,
                    fetchBalance: { throw error },
                    fetchSummary: {
                        Issue.record("Optional usage should not run")
                        throw DeepSeekUsageError.parseFailed("unexpected optional request")
                    })
            })
    }

    static func failure(_ resolution: DeepSeekPlatformTokenImporter.Resolution) async -> Error {
        do {
            _ = try await self.project(resolution)
            Issue.record("Expected browser balance failure")
            return DeepSeekUsageError.parseFailed("missing fixture failure")
        } catch {
            return error
        }
    }

    @MainActor
    static func withStore(
        prior: UsageSnapshot?,
        operation: @MainActor (UsageStore) async throws -> Void) async throws
    {
        try await ProviderTransportRegressionSupport.withStore(provider: .deepseek, hasPriorData: false) { store, _ in
            store.settings.updateProviderConfig(provider: .deepseek) { $0.source = .web }
            store._setSnapshotForTesting(prior, provider: .deepseek)
            store.lastKnownResetSnapshots[.deepseek] = prior
            store.lastSourceLabels[.deepseek] = prior == nil ? nil : "web"
            try await operation(store)
        }
    }

    @MainActor
    static func installAccountFailure(_ error: Error, on store: UsageStore) throws {
        let base = try #require(store.providerSpecs[.deepseek])
        let descriptor = ProviderDescriptor(
            id: .deepseek,
            credentials: base.descriptor.credentials,
            metadata: base.descriptor.metadata,
            branding: base.descriptor.branding,
            tokenCost: base.descriptor.tokenCost,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.web],
                pipeline: ProviderFetchPipeline { _ in [DeepSeekTransportFailureStrategy(error: error)] }),
            cli: base.descriptor.cli)
        store.providerSpecs[.deepseek] = ProviderSpec(
            style: base.style,
            isEnabled: base.isEnabled,
            descriptor: descriptor,
            makeFetchContext: base.makeFetchContext)
    }
}

private struct DeepSeekTransportFailureStrategy: ProviderFetchStrategy {
    let id = "deepseek.transport-fixture"
    let kind: ProviderFetchKind = .web
    let error: Error

    func isAvailable(_: ProviderFetchContext) async -> Bool { true }
    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult { throw self.error }
    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
}
