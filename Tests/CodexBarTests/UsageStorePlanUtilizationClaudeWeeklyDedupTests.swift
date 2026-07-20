import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension UsageStorePlanUtilizationTests {
    @MainActor
    @Test
    func `Claude weekly celebration ignores a stale high and duplicate low after reset`() async throws {
        let store = Self.makeStore()
        let accountLabel = "claude-weekly-dedup-account"
        let recorder = ClaudeWeeklyResetEventRecorder(accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let start = Date(timeIntervalSince1970: 1_784_174_200)
        let boundary = start.addingTimeInterval(4 * 24 * 60 * 60)
        let snapshots = [
            claudeWeeklyDedupSnapshot(
                accountLabel: accountLabel,
                usedPercent: 73,
                resetsAt: boundary,
                updatedAt: start),
            claudeWeeklyDedupSnapshot(
                accountLabel: accountLabel,
                usedPercent: 0,
                resetsAt: boundary,
                updatedAt: start.addingTimeInterval(10)),
            claudeWeeklyDedupSnapshot(
                accountLabel: accountLabel,
                usedPercent: 73,
                resetsAt: boundary,
                updatedAt: start.addingTimeInterval(20)),
            claudeWeeklyDedupSnapshot(
                accountLabel: accountLabel,
                usedPercent: 0,
                resetsAt: boundary,
                updatedAt: start.addingTimeInterval(25)),
        ]

        for snapshot in snapshots {
            await store.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: snapshot,
                now: snapshot.updatedAt)
        }

        #expect(recorder.count == 1)
        let state = try #require(store.weeklyLimitResetDetectorStates.values.first)
        #expect(state.wasAboveThreshold == false)
        #expect(state.recoveryAboveThresholdCount == 0)
    }

    @MainActor
    @Test
    func `Claude weekly recovery confirmation persists and later permits a new reset`() async throws {
        let firstStore = Self.makeStore()
        let accountLabel = "claude-weekly-persisted-dedup-account"
        let recorder = ClaudeWeeklyResetEventRecorder(accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let start = Date(timeIntervalSince1970: 1_784_200_000)
        let boundary = start.addingTimeInterval(4 * 24 * 60 * 60)
        let firstHigh = claudeWeeklyDedupSnapshot(
            accountLabel: accountLabel,
            usedPercent: 65,
            resetsAt: boundary,
            updatedAt: start)
        let firstReset = claudeWeeklyDedupSnapshot(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: boundary,
            updatedAt: start.addingTimeInterval(10))

        for snapshot in [firstHigh, firstReset] {
            await firstStore.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: snapshot,
                now: snapshot.updatedAt)
        }
        #expect(recorder.count == 1)

        let persistedStates = UsageStore.loadWeeklyLimitResetDetectorStates(
            from: firstStore.settings.userDefaults)
        let restartedStore = Self.makeStore()
        restartedStore.weeklyLimitResetDetectorStates = persistedStates

        let delayedStaleHigh = claudeWeeklyDedupSnapshot(
            accountLabel: accountLabel,
            usedPercent: 65,
            resetsAt: boundary,
            updatedAt: firstReset.updatedAt.addingTimeInterval(30 * 60))
        let duplicateLow = claudeWeeklyDedupSnapshot(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: boundary,
            updatedAt: firstReset.updatedAt.addingTimeInterval(31 * 60))

        for snapshot in [delayedStaleHigh, duplicateLow] {
            await restartedStore.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: snapshot,
                now: snapshot.updatedAt)
        }
        #expect(recorder.count == 1)
        var state = try #require(restartedStore.weeklyLimitResetDetectorStates.values.first)
        #expect(state.wasAboveThreshold == false)
        #expect(state.recoveryAboveThresholdCount == 0)

        let firstRecoveryHigh = claudeWeeklyDedupSnapshot(
            accountLabel: accountLabel,
            usedPercent: 40,
            resetsAt: boundary,
            updatedAt: firstReset.updatedAt.addingTimeInterval(60 * 60))
        await restartedStore.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: firstRecoveryHigh,
            now: firstRecoveryHigh.updatedAt)
        #expect(recorder.count == 1)
        state = try #require(restartedStore.weeklyLimitResetDetectorStates.values.first)
        #expect(state.wasAboveThreshold == false)
        #expect(state.recoveryAboveThresholdCount == 1)

        let recoveryStates = UsageStore.loadWeeklyLimitResetDetectorStates(
            from: restartedStore.settings.userDefaults)
        let secondRestartedStore = Self.makeStore()
        secondRestartedStore.weeklyLimitResetDetectorStates = recoveryStates

        let secondRecoveryHigh = claudeWeeklyDedupSnapshot(
            accountLabel: accountLabel,
            usedPercent: 45,
            resetsAt: boundary,
            updatedAt: firstReset.updatedAt.addingTimeInterval(65 * 60))
        let laterReset = claudeWeeklyDedupSnapshot(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: boundary,
            updatedAt: firstReset.updatedAt.addingTimeInterval(70 * 60))

        for snapshot in [secondRecoveryHigh, laterReset] {
            await secondRestartedStore.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: snapshot,
                now: snapshot.updatedAt)
        }
        #expect(recorder.count == 2)
    }

    @MainActor
    @Test
    func `Claude weekly recovery confirmation is isolated by account`() async {
        let store = Self.makeStore()
        let firstAccount = "claude-weekly-dedup-account-a"
        let secondAccount = "claude-weekly-dedup-account-b"
        let firstRecorder = ClaudeWeeklyResetEventRecorder(accountLabel: firstAccount)
        let secondRecorder = ClaudeWeeklyResetEventRecorder(accountLabel: secondAccount)
        defer {
            firstRecorder.invalidate()
            secondRecorder.invalidate()
        }

        let start = Date(timeIntervalSince1970: 1_784_300_000)
        let boundary = start.addingTimeInterval(4 * 24 * 60 * 60)
        let snapshots = [
            claudeWeeklyDedupSnapshot(
                accountLabel: firstAccount,
                usedPercent: 65,
                resetsAt: boundary,
                updatedAt: start),
            claudeWeeklyDedupSnapshot(
                accountLabel: firstAccount,
                usedPercent: 0,
                resetsAt: boundary,
                updatedAt: start.addingTimeInterval(1)),
            claudeWeeklyDedupSnapshot(
                accountLabel: firstAccount,
                usedPercent: 65,
                resetsAt: boundary,
                updatedAt: start.addingTimeInterval(30 * 60)),
            claudeWeeklyDedupSnapshot(
                accountLabel: secondAccount,
                usedPercent: 60,
                resetsAt: boundary,
                updatedAt: start.addingTimeInterval(31 * 60)),
            claudeWeeklyDedupSnapshot(
                accountLabel: secondAccount,
                usedPercent: 0,
                resetsAt: boundary,
                updatedAt: start.addingTimeInterval(32 * 60)),
            claudeWeeklyDedupSnapshot(
                accountLabel: firstAccount,
                usedPercent: 0,
                resetsAt: boundary,
                updatedAt: start.addingTimeInterval(33 * 60)),
        ]

        for snapshot in snapshots {
            await store.recordPlanUtilizationHistorySample(
                provider: .claude,
                snapshot: snapshot,
                now: snapshot.updatedAt)
        }

        #expect(firstRecorder.count == 1)
        #expect(secondRecorder.count == 1)
        #expect(store.weeklyLimitResetDetectorStates.count == 2)
        #expect(store.weeklyLimitResetDetectorStates.values.allSatisfy { !$0.wasAboveThreshold })
        #expect(store.weeklyLimitResetDetectorStates.values.allSatisfy {
            $0.recoveryAboveThresholdCount == 0
        })
    }

    @Test
    func `legacy reset detector state decodes without recovery state`() throws {
        let suiteName = "ClaudeWeeklyResetDedupLegacy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let data = Data(
            #"{"claude:legacy":{"wasAboveThreshold":true,"lastObservedAt":0}}"#.utf8)
        defaults.set(data, forKey: "legacyWeeklyResetStates")

        let states = UsageStore.loadLimitResetDetectorStates(
            from: defaults,
            defaultsKey: "legacyWeeklyResetStates",
            logName: "weekly")

        let state = try #require(states["claude:legacy"])
        #expect(state.wasAboveThreshold)
        #expect(state.recoveryAboveThresholdCount == nil)
        #expect(!state.pendingLowConfirmation)
    }

    @Test
    func `legacy Claude weekly low state migrates into recovery confirmation`() throws {
        let suiteName = "ClaudeWeeklyResetDedupLowMigration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let data = Data(
            """
            {
              "claude:legacy-low": {"wasAboveThreshold":false,"lastObservedAt":0},
              "codex:legacy-low": {"wasAboveThreshold":false,"lastObservedAt":0}
            }
            """.utf8)
        defaults.set(data, forKey: "weeklyLimitResetDetectorStates")

        let states = UsageStore.loadWeeklyLimitResetDetectorStates(from: defaults)

        #expect(states["claude:legacy-low"]?.recoveryAboveThresholdCount == 0)
        #expect(states["codex:legacy-low"]?.recoveryAboveThresholdCount == nil)
    }
}

private func claudeWeeklyDedupSnapshot(
    accountLabel: String,
    usedPercent: Double,
    resetsAt: Date,
    updatedAt: Date) -> UsageSnapshot
{
    UsageSnapshot(
        primary: RateWindow(
            usedPercent: 14,
            windowMinutes: 300,
            resetsAt: updatedAt.addingTimeInterval(5 * 60 * 60),
            resetDescription: nil),
        secondary: RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 7 * 24 * 60,
            resetsAt: resetsAt,
            resetDescription: nil),
        updatedAt: updatedAt,
        identity: ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: accountLabel,
            accountOrganization: nil,
            loginMethod: "web"))
}

private final class ClaudeWeeklyResetEventRecorder: @unchecked Sendable {
    private let accountLabel: String
    private let lock = NSLock()
    private var eventCount = 0
    private var observer: NSObjectProtocol?

    init(accountLabel: String) {
        self.accountLabel = accountLabel
        self.observer = NotificationCenter.default.addObserver(
            forName: .codexbarWeeklyLimitReset,
            object: nil,
            queue: nil)
        { [weak self] notification in
            guard let self,
                  let event = notification.object as? WeeklyLimitResetEvent
            else {
                return
            }

            let matches = MainActor.assumeIsolated {
                event.provider == .claude && event.accountLabel == self.accountLabel
            }
            guard matches else { return }

            self.lock.lock()
            self.eventCount += 1
            self.lock.unlock()
        }
    }

    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.eventCount
    }

    func invalidate() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }

    deinit {
        self.invalidate()
    }
}
