import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `fixed automatic codex ticks publish oauth usage and update the account snapshot file`() async throws {
        let suite = "CodexAutomaticRefreshPersistenceTests-fixed-account-snapshot"
        let email = "automatic-refresh@example.com"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .oneMinute
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: email,
            identity: .providerAccount(id: "acct-automatic-refresh"))
        defer { settings._test_liveSystemCodexAccount = nil }

        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-automatic-refresh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let snapshotStore = FileCodexAccountUsageSnapshotStore(fileURL: snapshotURL)
        let now = Date()
        let weeklyReset = now.addingTimeInterval(2 * 24 * 60 * 60)
        let stale = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 31,
            weeklyReset: weeklyReset,
            updatedAt: now.addingTimeInterval(-120))
        let firstTick = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 42,
            weeklyReset: weeklyReset,
            updatedAt: now.addingTimeInterval(-60))
        let secondTick = self.codexWeeklySnapshot(
            email: email,
            weeklyUsedPercent: 56,
            weeklyReset: weeklyReset,
            updatedAt: now)

        let seedStore = self.makeCodexWeeklyPublicationStore(
            settings: settings,
            suite: suite,
            snapshotStore: snapshotStore)
        self.installContextualCodexProvider(on: seedStore, sourceLabel: "oauth", kind: .oauth) { _ in stale }
        await seedStore.refreshProvider(.codex, allowDisabled: true)
        #expect(snapshotStore.load(for: settings.codexVisibleAccountProjection.visibleAccounts)
            .first?.snapshot?.secondary?.usedPercent == 31)

        let store = self.makeCodexWeeklyPublicationStore(
            settings: settings,
            suite: suite,
            snapshotStore: snapshotStore)
        store._test_tokenUsageRefreshOverride = { _, _ in }
        store._test_widgetSnapshotSaveOverride = { _ in }
        let loader = RecurringCodexSnapshotLoader(first: firstTick, subsequent: secondTick)
        self.installContextualCodexProvider(on: store, sourceLabel: "oauth", kind: .oauth) { _ in
            await loader.load()
        }

        store.restartTimerWithSleepOverrideForTesting(.milliseconds(30))
        defer {
            settings.refreshFrequency = .manual
            store.restartTimerWithSleepOverrideForTesting(nil)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            let persistedSnapshot = snapshotStore.load(
                for: settings.codexVisibleAccountProjection.visibleAccounts).first?.snapshot
            if store.completedRefreshCountForTesting >= 2, persistedSnapshot?.secondary?.usedPercent == 56 {
                break
            }
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }

        let persisted = try #require(snapshotStore.load(
            for: settings.codexVisibleAccountProjection.visibleAccounts).first)
        #expect(await loader.callCount >= 2)
        #expect(store.completedRefreshCountForTesting >= 2)
        #expect(store.snapshots[.codex]?.secondary?.usedPercent == 56)
        #expect(store.codexAccountSnapshots.first?.snapshot?.updatedAt == secondTick.updatedAt)
        #expect(persisted.account.workspaceAccountID == "acct-automatic-refresh")
        #expect(persisted.snapshot?.secondary?.usedPercent == 56)
        #expect(persisted.snapshot?.updatedAt == secondTick.updatedAt)
        #expect(persisted.sourceLabel == "oauth")
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
    }
}

private actor RecurringCodexSnapshotLoader {
    private let first: UsageSnapshot
    private let subsequent: UsageSnapshot
    private(set) var callCount = 0

    init(first: UsageSnapshot, subsequent: UsageSnapshot) {
        self.first = first
        self.subsequent = subsequent
    }

    func load() -> UsageSnapshot {
        defer { self.callCount += 1 }
        return self.callCount == 0 ? self.first : self.subsequent
    }
}
