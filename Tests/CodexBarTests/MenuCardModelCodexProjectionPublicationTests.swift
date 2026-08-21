import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

extension MenuCardModelCodexProjectionTests {
    @Test
    @MainActor
    func `codex profile card rejects incompatible raw token publication until current profile publishes`() throws {
        let (settings, store) = self.makeCodexTokenFixture(ambient: false)
        let profileA = "/tmp/codex-profile-a"
        let profileB = "/tmp/codex-profile-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let profileASnapshot = self.codexTokenSnapshot(cost: 1)
        store._setTokenSnapshotForTesting(profileASnapshot, provider: .codex)
        let controller = self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(try #require(controller.menuCardModel(for: .codex)).tokenUsage != nil)
        #expect(controller.openAIWebContext(currentProvider: .codex, showAllAccounts: false).hasCostHistory)
        #expect(controller.tokenSnapshotForCostHistorySubmenu(provider: .codex) == profileASnapshot)

        settings.codexActiveSource = .profileHome(path: profileB)

        #expect(store.tokenSnapshot(for: .codex) == profileASnapshot)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil)
        #expect(try #require(controller.menuCardModel(for: .codex)).tokenUsage == nil)
        #expect(!controller.openAIWebContext(currentProvider: .codex, showAllAccounts: false).hasCostHistory)
        #expect(controller.tokenSnapshotForCostHistorySubmenu(provider: .codex) == nil)
        #expect(controller.menuAdjunctReadinessSignature().contains("codex:token=none"))

        let profileBSnapshot = self.codexTokenSnapshot(cost: 2)
        store._setTokenSnapshotForTesting(profileBSnapshot, provider: .codex)

        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex)?.snapshot == profileBSnapshot)
        #expect(try #require(controller.menuCardModel(for: .codex)).tokenUsage != nil)
        #expect(controller.openAIWebContext(currentProvider: .codex, showAllAccounts: false).hasCostHistory)
        #expect(controller.tokenSnapshotForCostHistorySubmenu(provider: .codex) == profileBSnapshot)
        #expect(!controller.menuAdjunctReadinessSignature().contains("codex:token=none"))
    }

    @Test
    @MainActor
    func `codex ambient publication remains compatible across profile selection revisions`() throws {
        let (settings, store) = self.makeCodexTokenFixture(ambient: true)
        let profileA = "/tmp/codex-ambient-profile-a"
        let profileB = "/tmp/codex-ambient-profile-b"
        settings.updateProviderConfig(provider: .codex) { config in
            config.codexProfileHomePaths = [profileA, profileB]
            config.codexActiveSource = .profileHome(path: profileA)
        }
        let snapshot = self.codexTokenSnapshot(cost: 3)
        store._setTokenSnapshotForTesting(snapshot, provider: .codex)
        let publicationConfigRevision = settings.providerConfigRevision(for: .codex)
        let controller = self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }

        settings.codexActiveSource = .profileHome(path: profileB)

        #expect(settings.providerConfigRevision(for: .codex) != publicationConfigRevision)
        #expect(store.tokenCostScope(for: .codex).signature == UsageStore.codexAmbientTokenCostScopeSignature)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex)?.snapshot == snapshot)
        #expect(try #require(controller.menuCardModel(for: .codex)).tokenUsage != nil)
        #expect(controller.openAIWebContext(currentProvider: .codex, showAllAccounts: false).hasCostHistory)
        #expect(controller.tokenSnapshotForCostHistorySubmenu(provider: .codex) == snapshot)

        settings.costUsageHistoryDays += 1

        #expect(store.tokenSnapshot(for: .codex) == snapshot)
        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex) == nil)
    }

    @Test
    @MainActor
    func `mistral readiness fingerprints live provider projection without token publication`() throws {
        let (settings, store) = self.makeMistralTokenFixture()
        let controller = self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }
        let firstCost = 1.25
        let firstSnapshot = self.mistralUsageSnapshot(cost: firstCost).toUsageSnapshot()

        store._setSnapshotForTesting(firstSnapshot, provider: .mistral)

        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .mistral) == nil)
        let projected = try #require(store.tokenSnapshot(fromProviderSnapshot: firstSnapshot, provider: .mistral))
        #expect(projected.sessionCostUSD == firstCost)
        let firstSignature = controller.menuAdjunctReadinessSignature()
        #expect(!firstSignature.contains("mistral:token=none"))
        #expect(firstSignature.contains("sessionCost=\(String(firstCost.bitPattern, radix: 16))"))

        let secondCost = 2.5
        store._setSnapshotForTesting(
            self.mistralUsageSnapshot(cost: secondCost).toUsageSnapshot(),
            provider: .mistral)

        #expect(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .mistral) == nil)
        let secondSignature = controller.menuAdjunctReadinessSignature()
        #expect(secondSignature != firstSignature)
        #expect(secondSignature.contains("sessionCost=\(String(secondCost.bitPattern, radix: 16))"))
    }

    @Test
    @MainActor
    func `confirmed empty token publication invalidates menu observation without raw snapshot`() async throws {
        let (_, store) = self.makeCodexTokenFixture(ambient: false)
        let didChange = LockIsolated(false)
        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: {
            didChange.setValue(true)
        }

        store.publishConfirmedEmptyTokenSnapshot(for: .codex)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.tokenSnapshot(for: .codex) == nil)
        let publication = try #require(store.tokenSnapshotPublicationForCurrentProviderConfig(for: .codex))
        #expect(publication.snapshot == nil)
        #expect(didChange.value)
    }

    @MainActor
    private func makeCodexTokenFixture(ambient: Bool) -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(suiteName: "MenuCardModelCodexProjectionTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        settings.codexLocalSessionCostLedgerEnabled = ambient
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return (settings, store)
    }

    @MainActor
    private func makeMistralTokenFixture() -> (SettingsStore, UsageStore) {
        let settings = testSettingsStore(suiteName: "MenuCardModelCodexProjectionTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .mistral)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return (settings, store)
    }

    private func mistralUsageSnapshot(cost: Double) -> MistralUsageSnapshot {
        MistralUsageSnapshot(
            totalCost: cost,
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: 100,
            totalOutputTokens: 50,
            totalCachedTokens: 0,
            modelCount: 1,
            daily: [MistralDailyUsageBucket(
                day: "2026-08-22",
                cost: cost,
                inputTokens: 100,
                cachedTokens: 0,
                outputTokens: 50,
                models: [])],
            startDate: nil,
            endDate: nil,
            updatedAt: Date(timeIntervalSince1970: 1_787_356_800))
    }

    @MainActor
    private func makeController(settings: SettingsStore, store: UsageStore) -> StatusItemController {
        StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    private func codexTokenSnapshot(cost: Double) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: cost,
            last30DaysTokens: 20,
            last30DaysCostUSD: cost,
            currencyCode: "USD",
            daily: [CostUsageDailyReport.Entry(
                date: "2026-08-22",
                inputTokens: 4,
                outputTokens: 6,
                totalTokens: 10,
                costUSD: cost,
                modelsUsed: ["gpt-5"],
                modelBreakdowns: nil)],
            updatedAt: Date(timeIntervalSince1970: 1_787_356_800))
    }
}
