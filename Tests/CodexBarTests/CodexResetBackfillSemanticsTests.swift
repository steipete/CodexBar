import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexResetBackfillSemanticsTests {
    @Test
    func `merged reset cache preserves semantic lanes across swapped snapshots`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionReset = now.addingTimeInterval(4 * 60 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 24 * 60 * 60)
        let canonicalSessionCache = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 17,
                windowMinutes: 300,
                resetsAt: sessionReset,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now.addingTimeInterval(-20))
        let swappedWeeklyCache = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 63,
                windowMinutes: 10080,
                resetsAt: weeklyReset,
                resetDescription: nil),
            secondary: nil,
            updatedAt: now.addingTimeInterval(-10))

        let merged = try #require(UsageStore.codexMergedResetBackfillSnapshot(
            [canonicalSessionCache, swappedWeeklyCache],
            now: now))

        #expect(merged.primary?.usedPercent == 17)
        #expect(merged.primary?.windowMinutes == 300)
        #expect(merged.primary?.resetsAt == sessionReset)
        #expect(merged.secondary?.usedPercent == 63)
        #expect(merged.secondary?.windowMinutes == 10080)
        #expect(merged.secondary?.resetsAt == weeklyReset)
    }
}

extension CodexAccountScopedRefreshTests {
    @Test
    func `stacked email only rows use neither prior baselines nor reset backfills`() async throws {
        let fixture = try self.makeEmailOnlyStackedFixture(
            suite: "CodexResetBackfillSemanticsTests-email-only-stacked")
        defer { fixture.cleanup() }

        let now = Date()
        let weeklyReset = now.addingTimeInterval(3 * 24 * 60 * 60)
        let targetPrior = self.codexWeeklySnapshot(
            email: fixture.target.email,
            weeklyUsedPercent: 74,
            weeklyReset: weeklyReset,
            updatedAt: now.addingTimeInterval(-60))
        let siblingPrior = self.codexWeeklySnapshot(
            email: fixture.sibling.email,
            weeklyUsedPercent: 28,
            weeklyReset: weeklyReset,
            updatedAt: now.addingTimeInterval(-60))
        let priorRows = [
            CodexAccountUsageSnapshot(
                account: fixture.target,
                snapshot: targetPrior,
                error: nil,
                sourceLabel: "cached-target"),
            CodexAccountUsageSnapshot(
                account: fixture.sibling,
                snapshot: siblingPrior,
                error: nil,
                sourceLabel: "cached-sibling"),
        ]
        let snapshotStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: priorRows)
        let store = self.makeCodexWeeklyPublicationStore(
            settings: fixture.settings,
            suite: "CodexResetBackfillSemanticsTests-email-only-stacked",
            snapshotStore: snapshotStore)
        #expect(store.codexLimitResetOwnerKey(
            forVisibleAccount: fixture.target,
            visibleAccounts: [fixture.target, fixture.sibling]) == nil)

        let initialLow = self.codexWeeklySnapshot(
            email: fixture.target.email,
            weeklyUsedPercent: 0.2,
            weeklyReset: weeklyReset,
            updatedAt: now.addingTimeInterval(-40))
        let confirmedLow = self.codexWeeklySnapshot(
            email: fixture.target.email,
            weeklyUsedPercent: 0.4,
            weeklyReset: weeklyReset,
            updatedAt: now.addingTimeInterval(-30))
        let partial = self.codexWeeklySnapshot(
            email: fixture.target.email,
            weeklyUsedPercent: nil,
            weeklyReset: nil,
            updatedAt: now.addingTimeInterval(-20),
            sessionUsedPercent: 31)
        let targetLoader = SequencedCodexSnapshotLoader(steps: [
            .success(initialLow),
            .success(confirmedLow),
            .success(partial),
        ])
        let siblingCurrent = self.codexWeeklySnapshot(
            email: fixture.sibling.email,
            weeklyUsedPercent: 29,
            weeklyReset: weeklyReset,
            updatedAt: now.addingTimeInterval(-10))
        let targetHomePath = fixture.targetHome.path
        let siblingHomePath = fixture.siblingHome.path
        self.installContextualCodexProvider(on: store) { context in
            switch context.env["CODEX_HOME"] {
            case targetHomePath:
                try await targetLoader.load()
            case siblingHomePath:
                siblingCurrent
            default:
                throw TestRefreshError(message: "Unexpected CODEX_HOME routing")
            }
        }

        await store.refreshCodexVisibleAccountsForMenu()

        let confirmedTarget = try #require(store.codexAccountSnapshots.first {
            $0.account.storedAccountID == fixture.target.storedAccountID
        }?.snapshot)
        #expect(confirmedTarget.updatedAt == confirmedLow.updatedAt)
        #expect(confirmedTarget.secondary?.usedPercent == 0.4)

        await store.refreshCodexVisibleAccountsForMenu()

        let partialTarget = try #require(store.codexAccountSnapshots.first {
            $0.account.storedAccountID == fixture.target.storedAccountID
        }?.snapshot)
        #expect(await targetLoader.callCount == 3)
        #expect(partialTarget.updatedAt == partial.updatedAt)
        #expect(partialTarget.primary?.usedPercent == 31)
        #expect(partialTarget.secondary == nil)
    }

    private func makeEmailOnlyStackedFixture(suite: String) throws -> EmailOnlyStackedFixture {
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings.multiAccountMenuLayout = .stacked

        let targetID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-424242424242"))
        let siblingID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-434343434343"))
        let targetHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-email-only-target-\(UUID().uuidString)", isDirectory: true)
        let siblingHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-email-only-sibling-\(UUID().uuidString)", isDirectory: true)
        try Self.writeCodexAuthFile(
            homeURL: targetHome,
            email: "email-only-target@example.com",
            plan: "Pro")
        try Self.writeCodexAuthFile(
            homeURL: siblingHome,
            email: "email-only-sibling@example.com",
            plan: "Pro")
        let targetFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: targetHome.path))
        let siblingFingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: siblingHome.path))
        let targetAccount = ManagedCodexAccount(
            id: targetID,
            email: "email-only-target@example.com",
            authFingerprint: targetFingerprint,
            managedHomePath: targetHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let siblingAccount = ManagedCodexAccount(
            id: siblingID,
            email: "email-only-sibling@example.com",
            authFingerprint: siblingFingerprint,
            managedHomePath: siblingHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let accountStoreURL = try self.makeManagedAccountStoreURL(accounts: [targetAccount, siblingAccount])
        settings._test_managedCodexAccountStoreURL = accountStoreURL
        settings.codexActiveSource = .managedAccount(id: targetID)

        let projection = settings.codexVisibleAccountProjection
        let target = try #require(projection.visibleAccounts.first { $0.storedAccountID == targetID })
        let sibling = try #require(projection.visibleAccounts.first { $0.storedAccountID == siblingID })
        #expect(target.workspaceAccountID == nil)
        #expect(sibling.workspaceAccountID == nil)

        return EmailOnlyStackedFixture(
            settings: settings,
            target: target,
            sibling: sibling,
            targetHome: targetHome,
            siblingHome: siblingHome,
            accountStoreURL: accountStoreURL)
    }
}

private struct EmailOnlyStackedFixture {
    let settings: SettingsStore
    let target: CodexVisibleAccount
    let sibling: CodexVisibleAccount
    let targetHome: URL
    let siblingHome: URL
    let accountStoreURL: URL

    @MainActor
    func cleanup() {
        self.settings._test_managedCodexAccountStoreURL = nil
        try? FileManager.default.removeItem(at: self.accountStoreURL)
        try? FileManager.default.removeItem(at: self.targetHome)
        try? FileManager.default.removeItem(at: self.siblingHome)
    }
}
