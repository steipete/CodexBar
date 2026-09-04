import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `non active selected workspace does not adopt its auth default email history`() throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-non-active-selected-owner")
        settings.multiAccountMenuLayout = .stacked
        let accountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-565656565656"))
        let managedHome = CodexCredentialFixtures.root
            .appendingPathComponent("codex-non-active-selected-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "shared@example.com",
            plan: "pro",
            accountId: "auth-default")
        let selectedAccount = ManagedCodexAccount(
            id: accountID,
            email: "shared@example.com",
            providerAccountID: "selected-workspace",
            workspaceLabel: "Selected Team",
            workspaceAccountID: "selected-workspace",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [selectedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "active@example.com",
            identity: .providerAccount(id: "active-workspace"))
        settings.codexActiveSource = .liveSystem
        let store = self.makeUsageStore(settings: settings)
        let visibleAccount = try #require(settings.codexVisibleAccountProjection.visibleAccounts.first {
            $0.storedAccountID == accountID
        })
        let selectedHistoryKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(
            id: "selected-workspace")))
        let emailHistoryKey = CodexHistoryOwnership.canonicalEmailHashKey(for: "shared@example.com")
        let session = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_800_000_000), usedPercent: 1),
        ])
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            emailHistoryKey: [session],
        ])

        let histories = store.codexPlanUtilizationHistories(forVisibleAccount: visibleAccount)

        #expect(histories.isEmpty)
        #expect(store.planUtilizationHistory[.codex]?.accounts[selectedHistoryKey] == nil)
        #expect(store.planUtilizationHistory[.codex]?.accounts[emailHistoryKey] == [session])
    }

    @Test
    func `live merged selected workspace does not adopt hidden auth owner history`() throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-live-merged-selected-owner")
        let accountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-787878787878"))
        let managedHome = CodexCredentialFixtures.root
            .appendingPathComponent("codex-live-merged-selected-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "shared@example.com",
            plan: "pro",
            accountId: "auth-default")
        let selectedAccount = ManagedCodexAccount(
            id: accountID,
            email: "shared@example.com",
            providerAccountID: "selected-workspace",
            workspaceLabel: "Selected Team",
            workspaceAccountID: "selected-workspace",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [selectedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: managedHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "shared@example.com",
            identity: .providerAccount(id: "selected-workspace"))
        settings.codexActiveSource = .liveSystem
        let store = self.makeUsageStore(settings: settings)
        let selectedHistoryKey = try #require(CodexHistoryOwnership.canonicalKey(for: .providerAccount(
            id: "selected-workspace")))
        let emailHistoryKey = CodexHistoryOwnership.canonicalEmailHashKey(for: "shared@example.com")
        let unscoped = planSeries(name: .session, windowMinutes: 300, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_799_000_000), usedPercent: 1),
        ])
        let emailHistory = planSeries(name: .weekly, windowMinutes: 10080, entries: [
            planEntry(at: Date(timeIntervalSince1970: 1_800_000_000), usedPercent: 2),
        ])
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(
            unscoped: [unscoped],
            accounts: [emailHistoryKey: [emailHistory]])
        store._setSnapshotForTesting(
            self.codexSnapshot(email: "shared@example.com", usedPercent: 10),
            provider: .codex)

        let history = store.planUtilizationHistory(for: .codex)
        let buckets = try #require(store.planUtilizationHistory[.codex])

        #expect(settings.activeManagedCodexAccount == nil)
        #expect(settings.codexAccountReconciliationSnapshot.matchingStoredAccountForLiveSystemAccount?.id == accountID)
        #expect(history.isEmpty)
        #expect(buckets.unscoped == [unscoped])
        #expect(buckets.accounts[emailHistoryKey] == [emailHistory])
        #expect(buckets.accounts[selectedHistoryKey] == nil)
    }
}
