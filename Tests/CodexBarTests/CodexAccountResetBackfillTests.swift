import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension CodexAccountScopedRefreshTests {
    @Test
    func `visible account refresh backfills known reset time before storing snapshots`() async throws {
        let settings = self.makeSettingsStore(suite: "CodexAccountResetBackfillTests-backfill")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        settings._test_liveSystemCodexAccount = self.liveAccount(email: "live@example.com")
        settings.codexActiveSource = .liveSystem

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-222222222222"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }
        settings._test_managedCodexAccountStoreURL = storeURL

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let knownReset = Date().addingTimeInterval(3600)
        store.lastKnownResetSnapshots[.codex] = self.codexSnapshot(
            email: "live@example.com",
            usedPercent: 5,
            resetsAt: knownReset)
        self.installImmediateCodexProvider(
            on: store,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 6,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: "Resets 4:06 PM"),
                secondary: nil,
                updatedAt: Date(),
                identity: nil))

        await store.refreshCodexVisibleAccountsForMenu()

        let liveSnapshot = try #require(snapshotStore.storedSnapshots.first { $0.account.email == "live@example.com" })
        let managedSnapshot = try #require(snapshotStore.storedSnapshots
            .first { $0.account.email == "managed@example.com" })
        #expect(liveSnapshot.snapshot?.primary?.resetsAt == knownReset)
        #expect(store.codexAccountSnapshots.first { $0.account.email == "live@example.com" }?.snapshot?.primary?
            .resetsAt == knownReset)
        #expect(managedSnapshot.snapshot?.primary?.resetsAt == nil)
    }
}
