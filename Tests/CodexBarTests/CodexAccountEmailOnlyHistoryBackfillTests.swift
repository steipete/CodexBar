import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `email only plan history never backfills quota publication`() async throws {
        let settings = self.makeSettingsStore(
            suite: "CodexAccountVisibleHistoryBackfillTests-non-active-email-history")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked

        let activeID = try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-333333333333"))
        let siblingID = try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-444444444444"))
        let activeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-active-email-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-visible-sibling-email-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: activeHome,
            email: "active-email-history@example.com",
            plan: "Pro")
        try Self.writeCodexAuthFile(
            homeURL: siblingHome,
            email: "sibling-email-history@example.com",
            plan: "Pro")
        let activeFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: activeHome.path))
        let siblingFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: siblingHome.path))
        let activeAccount = ManagedCodexAccount(
            id: activeID,
            email: "active-email-history@example.com",
            workspaceLabel: "Active Team",
            authFingerprint: activeFingerprint,
            managedHomePath: activeHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "sibling-email-history@example.com",
            workspaceLabel: "Sibling Team",
            authFingerprint: siblingFingerprint,
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [activeAccount, siblingAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: activeHome)
            try? FileManager.default.removeItem(at: siblingHome)
        }
        settings._test_managedCodexAccountStoreURL = storeURL
        settings.codexActiveSource = .managedAccount(id: activeID)

        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            codexAccountUsageSnapshotStore: snapshotStore,
            startupBehavior: .testing)
        let now = Date()
        let sessionReset = now.addingTimeInterval(2 * 60 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 24 * 60 * 60)
        let siblingHistoryKey = CodexHistoryOwnership.canonicalEmailHashKey(for: "sibling-email-history@example.com")
        store.planUtilizationHistory[.codex] = PlanUtilizationHistoryBuckets(accounts: [
            siblingHistoryKey: [
                planSeries(name: .session, windowMinutes: 300, entries: [
                    planEntry(at: now.addingTimeInterval(-60), usedPercent: 6, resetsAt: sessionReset),
                ]),
                planSeries(name: .weekly, windowMinutes: 10080, entries: [
                    planEntry(at: now.addingTimeInterval(-60), usedPercent: 36, resetsAt: weeklyReset),
                ]),
            ],
        ])
        store.lastCodexAccountScopedRefreshGuard = CodexAccountScopedRefreshGuard(
            source: .managedAccount(id: activeID),
            identity: .emailOnly(normalizedEmail: "active-email-history@example.com"),
            accountKey: "active-email-history@example.com",
            authFingerprint: activeFingerprint)
        self.installContextualCodexProvider(on: store) { context in
            let isActive = context.env["CODEX_HOME"] == activeHome.path
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: isActive ? 3 : 6,
                    windowMinutes: 0,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now)
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let activeSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.email == "active-email-history@example.com"
        }?.snapshot)
        #expect(activeSnapshot.primary?.usedPercent == 3)
        #expect(activeSnapshot.primary?.windowMinutes == 0)
        #expect(activeSnapshot.primary?.resetsAt == nil)

        let siblingSnapshot = try #require(store.codexAccountSnapshots.first {
            $0.account.email == "sibling-email-history@example.com"
        }?.snapshot)
        #expect(siblingSnapshot.primary?.usedPercent == 6)
        #expect(siblingSnapshot.primary?.windowMinutes == 0)
        #expect(siblingSnapshot.primary?.resetsAt == nil)
        #expect(siblingSnapshot.secondary == nil)
        let persistedSibling = try #require(snapshotStore.storedSnapshots.first {
            $0.account.email == "sibling-email-history@example.com"
        }?.snapshot)
        #expect(persistedSibling.primary?.resetsAt == nil)
        #expect(persistedSibling.secondary == nil)
    }
}
