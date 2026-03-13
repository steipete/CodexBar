import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct AdaptiveRefreshSchedulerTests {
    @Test
    func persistedRateLimitBackoffBlocksFirstRefreshAfterRelaunch() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let defaults = self.makeDefaults()

        let writer = AdaptiveRefreshScheduler(userDefaults: defaults, now: now)
        writer.recordRateLimit(for: .claude, retryAfter: 1_200, now: now)

        let restored = AdaptiveRefreshScheduler(userDefaults: defaults, now: now.addingTimeInterval(60))
        #expect(restored.shouldRefresh(for: .claude, snapshot: nil, now: now.addingTimeInterval(600)) == false)
        #expect(restored.shouldRefresh(for: .claude, snapshot: nil, now: now.addingTimeInterval(3_599)) == false)
        #expect(restored.shouldRefresh(for: .claude, snapshot: nil, now: now.addingTimeInterval(3_601)))
    }

    @Test
    func nextIntervalUsesRemainingTimeAcrossProviders() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = AdaptiveRefreshScheduler(userDefaults: self.makeDefaults(), now: now)
        let activeSnapshot = self.makeSnapshot(updatedAt: now, usedPercent: 80)

        scheduler.recordRefresh(for: .codex, now: now)
        scheduler.recordActivity(for: .codex, now: now)
        scheduler.recordRefresh(for: .claude, now: now)
        scheduler.recordRateLimit(for: .claude, retryAfter: 1_800, now: now)

        let interval = scheduler.nextInterval(
            providers: [.codex, .claude],
            snapshots: [.codex: activeSnapshot, .claude: activeSnapshot],
            maxInterval: 1_800,
            now: now.addingTimeInterval(10))

        let resolvedInterval = try #require(interval)
        #expect(abs(resolvedInterval - 5) < 0.001)
    }

    @Test
    func claudeMinimumFloorDrivesRemainingInterval() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = AdaptiveRefreshScheduler(userDefaults: self.makeDefaults(), now: now)
        let activeSnapshot = self.makeSnapshot(updatedAt: now, usedPercent: 90)

        scheduler.recordRefresh(for: .claude, now: now)
        scheduler.recordActivity(for: .claude, now: now)

        let interval = scheduler.nextInterval(
            providers: [.claude],
            snapshots: [.claude: activeSnapshot],
            maxInterval: 4_000,
            now: now.addingTimeInterval(100))

        let resolvedInterval = try #require(interval)
        #expect(abs(resolvedInterval - 3_500) < 0.001)
    }

    @Test
    func rateLimitBackoffDoesNotUndercutProviderFloor() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = AdaptiveRefreshScheduler(userDefaults: self.makeDefaults(), now: now)

        scheduler.recordRateLimit(for: .claude, retryAfter: 60, now: now)

        #expect(scheduler.shouldRefresh(for: .claude, snapshot: nil, now: now.addingTimeInterval(600)) == false)
        #expect(scheduler.shouldRefresh(for: .claude, snapshot: nil, now: now.addingTimeInterval(3_599)) == false)
        #expect(scheduler.shouldRefresh(for: .claude, snapshot: nil, now: now.addingTimeInterval(3_601)))
    }

    @Test
    func forceRefreshBypassesBackoffGate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let scheduler = AdaptiveRefreshScheduler(userDefaults: self.makeDefaults(), now: now)

        scheduler.recordRateLimit(for: .claude, retryAfter: 1_800, now: now)

        #expect(scheduler.shouldRefresh(
            for: .claude,
            snapshot: nil,
            force: true,
            now: now.addingTimeInterval(60)))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AdaptiveRefreshSchedulerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeSnapshot(updatedAt: Date, usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: updatedAt.addingTimeInterval(300),
                resetDescription: nil),
            secondary: nil,
            updatedAt: updatedAt)
    }
}
