import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    nonisolated static let codexSnapshotWaitTimeoutSeconds: TimeInterval = 6
    nonisolated static let codexSnapshotPollIntervalNanoseconds: UInt64 = 100_000_000

    func refreshCreditsIfNeeded(minimumSnapshotUpdatedAt: Date? = nil) async {
        guard self.isEnabled(.codex) else { return }
        do {
            let credits = try await self.codexFetcher.loadLatestCredits(
                keepCLISessionsAlive: self.settings.debugKeepCLISessionsAlive)
            await MainActor.run {
                self.credits = credits
                self.lastCreditsError = nil
                self.lastCreditsSnapshot = credits
                self.creditsFailureStreak = 0
            }
            let codexSnapshot = await MainActor.run {
                self.snapshots[.codex]
            }
            if let minimumSnapshotUpdatedAt,
               codexSnapshot == nil || codexSnapshot?.updatedAt ?? .distantPast < minimumSnapshotUpdatedAt
            {
                self.scheduleCodexPlanHistoryBackfill(
                    minimumSnapshotUpdatedAt: minimumSnapshotUpdatedAt)
                return
            }

            self.cancelCodexPlanHistoryBackfill()
            guard let codexSnapshot else { return }
            await self.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: codexSnapshot,
                now: codexSnapshot.updatedAt)
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("data not available yet") {
                await MainActor.run {
                    if let cached = self.lastCreditsSnapshot {
                        self.credits = cached
                        self.lastCreditsError = nil
                    } else {
                        self.credits = nil
                        self.lastCreditsError = "Codex credits are still loading; will retry shortly."
                    }
                }
                return
            }

            await MainActor.run {
                self.creditsFailureStreak += 1
                if let cached = self.lastCreditsSnapshot {
                    self.credits = cached
                    let stamp = cached.updatedAt.formatted(date: .abbreviated, time: .shortened)
                    self.lastCreditsError =
                        "Last Codex credits refresh failed: \(message). Cached values from \(stamp)."
                } else {
                    self.lastCreditsError = message
                    self.credits = nil
                }
            }
        }
    }

    func waitForCodexSnapshot(minimumUpdatedAt: Date) async -> UsageSnapshot? {
        let deadline = Date().addingTimeInterval(Self.codexSnapshotWaitTimeoutSeconds)

        while Date() < deadline {
            if Task.isCancelled { return nil }
            if let snapshot = await MainActor.run(body: { self.snapshots[.codex] }),
               snapshot.updatedAt >= minimumUpdatedAt
            {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: Self.codexSnapshotPollIntervalNanoseconds)
        }

        return nil
    }

    func scheduleCodexPlanHistoryBackfill(
        minimumSnapshotUpdatedAt: Date)
    {
        self.cancelCodexPlanHistoryBackfill()
        self.codexPlanHistoryBackfillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let snapshot = await self.waitForCodexSnapshot(minimumUpdatedAt: minimumSnapshotUpdatedAt) else {
                return
            }
            await self.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                now: snapshot.updatedAt)
            self.codexPlanHistoryBackfillTask = nil
        }
    }

    func cancelCodexPlanHistoryBackfill() {
        self.codexPlanHistoryBackfillTask?.cancel()
        self.codexPlanHistoryBackfillTask = nil
    }
}
