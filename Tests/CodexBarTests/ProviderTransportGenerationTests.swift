import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, ClaudeOAuthDefaultsFixtures(), ProviderTransportRegressionFixtures())
@MainActor
struct ProviderTransportGenerationTests {
    @Test(arguments: [UsageProvider.claude, .cursor, .vertexai, .ollama])
    func `a retired refresh cannot clear or relabel newer provider data`(provider: UsageProvider) async throws {
        try await ProviderTransportRegressionSupport.withStore(provider: provider) { store, prior in
            let fresh = UsageSnapshot(
                primary: prior.primary,
                secondary: prior.secondary,
                updatedAt: prior.updatedAt.addingTimeInterval(60),
                identity: ProviderIdentitySnapshot(
                    providerID: provider.instanceID,
                    accountEmail: "next@example.test",
                    accountOrganization: nil,
                    loginMethod: "Fresh account"))
            store._test_providerFetchOutcomeOverride = { _ in
                store.clearDisabledProviderState(enabledProviders: [])
                store._setSnapshotForTesting(fresh, provider: provider)
                return ProviderFetchOutcome(
                    result: .failure(ProviderTransportRegressionSupport.urlError()),
                    attempts: [])
            }
            await store.refreshProvider(provider)
            #expect(store.snapshot(for: provider.instanceID)?.updatedAt == fresh.updatedAt)
            #expect(store.snapshot(for: provider.instanceID)?.identity?.accountEmail == "next@example.test")
            #expect(store.errors[provider.instanceID] == nil)
            #expect((store.failureGates[provider.instanceID]?.streak ?? 0) == 0)
        }
    }
}
