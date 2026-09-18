import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, ClaudeOAuthDefaultsFixtures(), ProviderTransportRegressionFixtures())
@MainActor
struct DeepSeekTransportRetentionTests {
    private typealias Fixture = DeepSeekTransportTestSupport

    @Test
    func `repeated Chrome balance outages keep the same live snapshot and widget timestamp`() async throws {
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        let prior = try await Fixture.project(Fixture.successfulResolution(candidate: Fixture.candidateA, cache: cache))
        let error = await Fixture.failure(Fixture.failedResolution(candidates: [Fixture.candidateA], cache: cache))
        try await Fixture.withStore(prior: prior) { store in
            var saved: WidgetSnapshot?
            store._test_widgetSnapshotSaveOverride = { saved = $0 }
            store._test_providerFetchOutcomeOverride = { _ in .init(result: .failure(error), attempts: []) }
            for _ in 0..<2 {
                await store.refreshProvider(.deepseek)
            }
            #expect(store.snapshots[.deepseek]?.primary == prior.primary)
            #expect(store.snapshots[.deepseek]?.deepseekPlatformBalanceOwner == prior.deepseekPlatformBalanceOwner)
            #expect(store.snapshots[.deepseek]?.updatedAt == prior.updatedAt)
            #expect(store.lastSourceLabels[.deepseek] == "web")
            #expect(store.errors[.deepseek] == error.localizedDescription)
            store.persistWidgetSnapshot(reason: "deepseek-owned-outage")
            await store.widgetSnapshotPersistTask?.value
            let entry = try #require(saved?.entries.first { $0.provider == .deepseek })
            #expect(entry.primary == prior.primary)
            #expect(entry.updatedAt == prior.updatedAt)
        }
    }

    @Test(arguments: ["cached-other-profile", "changed-token", "decoded", "unowned", "no-prior"])
    func `an outage cannot retain balance without matching live ownership`(scenario: String) async throws {
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        _ = await Fixture.successfulResolution(candidate: Fixture.candidateB, cache: cache)
        let original = try await Fixture.project(Fixture.successfulResolution(
            candidate: Fixture.candidateA,
            cache: cache))
        let attempted = scenario == "cached-other-profile" ? Fixture.candidateB : scenario == "changed-token"
            ? Fixture.candidate(Fixture.candidateA.id, token: "replacement-token") : Fixture.candidateA
        let error = await Fixture.failure(Fixture.failedResolution(candidates: [attempted], cache: cache))
        let prior: UsageSnapshot? = switch scenario {
        case "decoded": try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(original))
        case "unowned": Fixture.balance().toUsageSnapshot()
        case "no-prior": nil
        default: original
        }
        #expect(UsageStore.isStartupConnectivityRetryableError(error))
        try await Fixture.withStore(prior: prior) { store in
            store._test_providerFetchOutcomeOverride = { _ in .init(result: .failure(error), attempts: []) }
            for _ in 0..<2 {
                await store.refreshProvider(.deepseek)
            }
            #expect(store.snapshots[.deepseek] == nil)
            #expect(store.errors[.deepseek] == error.localizedDescription)
            var saved: WidgetSnapshot?
            store._test_widgetSnapshotSaveOverride = { saved = $0 }
            store.persistWidgetSnapshot(reason: "deepseek-owner-mismatch")
            await store.widgetSnapshotPersistTask?.value
            #expect(saved?.entries.contains { $0.provider == .deepseek } == false)
        }
    }

    @Test(arguments: [false, true])
    func `URL cancellation suppresses errors only for the same live owner`(matches: Bool) async throws {
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        let prior = try await Fixture.project(Fixture.successfulResolution(candidate: Fixture.candidateA, cache: cache))
        let error = await Fixture.failure(Fixture.failedResolution(
            candidates: [matches ? Fixture.candidateA : Fixture.candidateB],
            cache: cache,
            error: ProviderTransportRegressionSupport.urlError(.cancelled)))
        try await Fixture.withStore(prior: prior) { store in
            store._test_providerFetchOutcomeOverride = { _ in .init(result: .failure(error), attempts: []) }
            for _ in 0..<2 {
                await store.refreshProvider(.deepseek)
            }
            if matches {
                #expect(store.snapshots[.deepseek]?.primary == prior.primary)
                #expect(store.errors[.deepseek] == nil)
                #expect(store.failureGates[.deepseek]?.streak == 0)
            } else {
                #expect(store.snapshots[.deepseek] == nil)
                #expect(store.errors[.deepseek] == error.localizedDescription)
            }
        }
    }

    @Test(arguments: [URLError.Code.cannotFindHost, .cancelled])
    func `an outage after a known session rejection cannot retain the old live balance`(
        code: URLError.Code) async throws
    {
        let cache = DeepSeekPlatformValidationCache()
        let prior = try await Fixture.project(Fixture.successfulResolution(candidate: Fixture.candidateA, cache: cache))
        let rejection = DeepSeekValidationSequence(last: "auth")
        try await Fixture.withStore(prior: prior) { store in
            let rejected = await DeepSeekPlatformTokenImporter._resolvePlatformBalanceForTesting(
                candidates: [Fixture.candidateA],
                selectedProfileID: Fixture.candidateA.id,
                cache: cache,
                validate: { _ in try await rejection.next() })
            #expect(await rejection.count == 2)
            #expect(rejected.selectedTransportError == nil)
            let firstError = await Fixture.failure(rejected)
            store._test_providerFetchOutcomeOverride = { _ in .init(result: .failure(firstError), attempts: []) }
            await store.refreshProvider(.deepseek)
            #expect(store.snapshots[.deepseek]?.primary == prior.primary)
            #expect(store.failureGates[.deepseek]?.streak == 1)
            let rejectedStatus = await cache.lookup(candidate: Fixture.candidateA, now: Date())
            #expect(rejectedStatus.lastKnownStatus == false)

            let outage = await Fixture.failedResolution(
                candidates: [Fixture.candidateA],
                selectedProfileID: Fixture.candidateA.id,
                cache: cache,
                error: ProviderTransportRegressionSupport.urlError(code))
            let transport = try #require(outage.selectedTransportError)
            #expect(transport.owner == nil)
            let secondError = await Fixture.failure(outage)
            #expect(UsageStore.isStartupConnectivityRetryableError(secondError) == (code != .cancelled))
            #expect(!UsageStore.shouldPreservePriorSnapshot(
                after: secondError, hadPriorData: true, priorSnapshot: prior))
            store._test_providerFetchOutcomeOverride = { _ in .init(result: .failure(secondError), attempts: []) }
            await store.refreshProvider(.deepseek)
            #expect(store.snapshots[.deepseek] == nil)
            #expect(store.failureGates[.deepseek]?.streak == 2)

            let restored = try await Fixture.project(Fixture.successfulResolution(
                candidate: Fixture.candidateA,
                cache: cache,
                selectedProfileID: Fixture.candidateA.id))
            let restoredStatus = await cache.lookup(candidate: Fixture.candidateA, now: Date())
            #expect(restoredStatus.lastKnownStatus == true)
            let later = await Fixture.failedResolution(
                candidates: [Fixture.candidateA], selectedProfileID: Fixture.candidateA.id, cache: cache)
            #expect(later.selectedTransportError?.owner == restored.deepseekPlatformBalanceOwner)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func `account rows and selected publication both check browser ownership before cancellation`(
        matches: Bool,
        useBatch: Bool) async throws
    {
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        let prior = try await Fixture.project(Fixture.successfulResolution(candidate: Fixture.candidateA, cache: cache))
        let attempted = matches ? Fixture.candidateA : Fixture.candidate(
            Fixture.candidateA.id,
            token: "replacement-token")
        let error = await Fixture.failure(Fixture.failedResolution(
            candidates: [attempted],
            cache: cache,
            error: ProviderTransportRegressionSupport.urlError(.cancelled)))
        try await Fixture.withStore(prior: nil) { store in
            store.settings.addTokenAccount(provider: .deepseek, label: "Synthetic", token: "synthetic-api-token")
            let account = try #require(store.settings.effectiveSelectedTokenAccount(for: .deepseek))
            store.settings.updateProviderConfig(provider: .deepseek) { $0.source = .web }
            store.settings.setDeepSeekProfileID(Fixture.candidateA.id, apiKey: account.token)
            store.cacheTokenAccountSnapshot(provider: .deepseek, account: account, snapshot: prior, sourceLabel: "web")
            store._setSnapshotForTesting(prior, provider: .deepseek)
            try Fixture.installAccountFailure(error, on: store)
            let fallback = try #require(store.accountSnapshots[.deepseek]?.first)
            for _ in 0..<2 {
                if useBatch {
                    await store.refreshTokenAccounts(provider: .deepseek, accounts: [account])
                } else {
                    await store.applySelectedOutcome(
                        .init(result: .failure(error), attempts: []),
                        provider: .deepseek,
                        account: account,
                        fallbackSnapshot: prior,
                        fallbackAccountSnapshot: fallback)
                }
            }
            let cached = try #require(store.accountSnapshots[.deepseek]?.first)
            if matches {
                #expect(cached.snapshot?.deepseekPlatformBalanceOwner == prior.deepseekPlatformBalanceOwner)
                #expect(cached.snapshot?.updatedAt == prior.updatedAt)
                #expect(store.snapshots[.deepseek]?.primary == prior.primary)
                #expect(store.errors[.deepseek] == nil)
            } else {
                if useBatch { #expect(cached.snapshot == nil) }
                #expect(store.snapshots[.deepseek] == nil)
                #expect(store.errors[.deepseek] == error.localizedDescription)
            }
        }
    }

    @Test
    func `selected cancellation restores the validated cached balance after debug loading clears publication`()
    async throws {
        try await self.expectSelectedCancellationRestoresCachedBalance(replacingAnotherOwner: false)
    }

    @Test
    func `selected cancellation publishes its validated cache instead of a different live owner`() async throws {
        try await self.expectSelectedCancellationRestoresCachedBalance(replacingAnotherOwner: true)
    }

    private func expectSelectedCancellationRestoresCachedBalance(replacingAnotherOwner: Bool) async throws {
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        let prior = try await Fixture.project(Fixture.successfulResolution(candidate: Fixture.candidateB, cache: cache))
        let other = try await Fixture.project(Fixture.successfulResolution(candidate: Fixture.candidateA, cache: cache))
        let error = await Fixture.failure(Fixture.failedResolution(
            candidates: [Fixture.candidateB],
            cache: cache,
            error: ProviderTransportRegressionSupport.urlError(.cancelled)))
        try await Fixture.withStore(prior: nil) { store in
            store.settings.addTokenAccount(provider: .deepseek, label: "Synthetic", token: "synthetic-api-token")
            let account = try #require(store.settings.effectiveSelectedTokenAccount(for: .deepseek))
            store.settings.updateProviderConfig(provider: .deepseek) { $0.source = .web }
            store.settings.setDeepSeekProfileID(Fixture.candidateB.id, apiKey: account.token)
            store.cacheTokenAccountSnapshot(provider: .deepseek, account: account, snapshot: prior, sourceLabel: "web")
            let fallback = try #require(store.accountSnapshots[.deepseek]?.first)
            store._setSnapshotForTesting(replacingAnotherOwner ? other : nil, provider: .deepseek)
            store.lastKnownResetSnapshots[.deepseek] = other
            store.lastSourceLabels[.deepseek] = "stale-source"
            store.errors[.deepseek] = "previous error"

            await store.applySelectedOutcome(
                .init(result: .failure(error), attempts: []),
                provider: .deepseek,
                account: account,
                fallbackSnapshot: prior,
                fallbackAccountSnapshot: fallback)

            #expect(store.snapshots[.deepseek]?.deepseekPlatformBalanceOwner == prior.deepseekPlatformBalanceOwner)
            #expect(store.snapshots[.deepseek]?.primary == prior.primary)
            #expect(store.snapshots[.deepseek]?.updatedAt == prior.updatedAt)
            #expect(store.lastKnownResetSnapshots[.deepseek]?.deepseekPlatformBalanceOwner == prior
                .deepseekPlatformBalanceOwner)
            #expect(store.lastKnownResetSnapshots[.deepseek]?.updatedAt == prior.updatedAt)
            #expect(store.lastSourceLabels[.deepseek] == "web")
            #expect(store.errors[.deepseek] == nil)
            #expect(store.failureGates[.deepseek]?.streak == 0)
        }
    }

    @Test
    func `a retired Chrome refresh cannot remove a newer owner snapshot`() async throws {
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        let old = try await Fixture.project(Fixture.successfulResolution(candidate: Fixture.candidateA, cache: cache))
        let fresh = try await Fixture.project(Fixture.successfulResolution(candidate: Fixture.candidateB, cache: cache))
        let error = await Fixture.failure(Fixture.failedResolution(candidates: [Fixture.candidateA], cache: cache))
        try await Fixture.withStore(prior: old) { store in
            store._test_providerFetchOutcomeOverride = { _ in
                store.clearDisabledProviderState(enabledProviders: [])
                store._setSnapshotForTesting(fresh, provider: .deepseek)
                return .init(result: .failure(error), attempts: [])
            }
            await store.refreshProvider(.deepseek)
            #expect(store.snapshots[.deepseek]?.deepseekPlatformBalanceOwner == fresh.deepseekPlatformBalanceOwner)
            #expect(store.errors[.deepseek] == nil)
            #expect(store.failureGates[.deepseek]?.streak == 0)
        }
    }

    @Test
    func `real task cancellation remains a cancelled operation instead of a failure publication`() async throws {
        let prior = try await Fixture.project(Fixture.successfulResolution(
            candidate: Fixture.candidateA,
            cache: .init()))
        try await Fixture.withStore(prior: prior) { store in
            store._test_providerFetchOutcomeOverride = { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(result: .failure(CancellationError()), attempts: [])
            }
            let refresh = Task { await store.refreshProvider(.deepseek) }
            await refresh.value
            #expect(store.snapshots[.deepseek]?.primary == prior.primary)
            #expect(store.errors[.deepseek] == nil)
            #expect(store.failureGates[.deepseek]?.streak == 0)
        }
    }
}
