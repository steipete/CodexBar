import CodexBarCore
import Foundation

extension UsageStore {
    private struct ResetBoundaryRefreshCandidate {
        var refreshAt: Date
        var boundaryRefreshAt: Date
    }

    func scheduleResetBoundaryRefreshIfNeeded(
        normalRefreshInterval: TimeInterval?,
        now: Date = Date())
    {
        guard let candidate = Self.nextResetBoundaryRefreshCandidate(
            snapshots: self.snapshots,
            normalRefreshInterval: normalRefreshInterval,
            attemptedBoundaryRefreshes: self.attemptedResetBoundaryRefreshes,
            now: now)
        else {
            self.cancelResetBoundaryRefresh()
            return
        }

        let refreshAt = candidate.refreshAt
        if let scheduledResetBoundaryRefreshAt,
           abs(scheduledResetBoundaryRefreshAt.timeIntervalSince(refreshAt)) < 1
        {
            return
        }

        self.cancelResetBoundaryRefresh()
        self.scheduledResetBoundaryRefreshAt = refreshAt
        self.resetBoundaryRefreshTask = Task.detached(priority: .utility) { [weak self] in
            let delay = max(0, refreshAt.timeIntervalSince(Date()))
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.runResetBoundaryRefresh(boundaryRefreshAt: candidate.boundaryRefreshAt)
        }
    }

    func runResetBoundaryRefresh(boundaryRefreshAt: Date) async {
        self.resetBoundaryRefreshTask = nil
        self.scheduledResetBoundaryRefreshAt = nil
        guard Self.shouldRecordResetBoundaryAttempt(isRefreshing: self.isRefreshing) else { return }
        self.recordAttemptedResetBoundaryRefresh(boundaryRefreshAt)
        await self.refresh()
    }

    private func recordAttemptedResetBoundaryRefresh(_ refreshAt: Date) {
        self.attemptedResetBoundaryRefreshes.insert(refreshAt)
        if self.attemptedResetBoundaryRefreshes.count > 64,
           let oldest = self.attemptedResetBoundaryRefreshes.min()
        {
            self.attemptedResetBoundaryRefreshes.remove(oldest)
        }
    }

    func cancelResetBoundaryRefresh() {
        self.resetBoundaryRefreshTask?.cancel()
        self.resetBoundaryRefreshTask = nil
        self.scheduledResetBoundaryRefreshAt = nil
    }

    nonisolated static func nextResetBoundaryRefreshDate(
        snapshots: [UsageProvider: UsageSnapshot],
        normalRefreshInterval: TimeInterval?,
        attemptedBoundaryRefreshes: Set<Date> = [],
        now: Date)
        -> Date?
    {
        self.nextResetBoundaryRefreshCandidate(
            snapshots: snapshots,
            normalRefreshInterval: normalRefreshInterval,
            attemptedBoundaryRefreshes: attemptedBoundaryRefreshes,
            now: now)?
            .refreshAt
    }

    nonisolated static func shouldRecordResetBoundaryAttempt(isRefreshing: Bool) -> Bool {
        !isRefreshing
    }

    private nonisolated static func nextResetBoundaryRefreshCandidate(
        snapshots: [UsageProvider: UsageSnapshot],
        normalRefreshInterval: TimeInterval?,
        attemptedBoundaryRefreshes: Set<Date> = [],
        now: Date)
        -> ResetBoundaryRefreshCandidate?
    {
        guard let normalRefreshInterval else { return nil }
        let normalRefreshDate = now.addingTimeInterval(normalRefreshInterval)
        return snapshots.values
            .flatMap { snapshot in
                Self.resetBoundaryRefreshCandidates(
                    snapshot: snapshot,
                    now: now,
                    normalRefreshDate: normalRefreshDate,
                    attemptedBoundaryRefreshes: attemptedBoundaryRefreshes)
            }
            .min { $0.refreshAt < $1.refreshAt }
    }

    private nonisolated static func resetBoundaryRefreshCandidates(
        snapshot: UsageSnapshot,
        now: Date,
        normalRefreshDate: Date,
        attemptedBoundaryRefreshes: Set<Date>)
        -> [ResetBoundaryRefreshCandidate]
    {
        snapshot.allRateWindows().compactMap { window in
            guard let resetsAt = window.resetsAt else { return nil }
            let boundaryRefreshAt = resetsAt.addingTimeInterval(Self.resetBoundaryRefreshGraceSeconds)
            guard !attemptedBoundaryRefreshes.contains(boundaryRefreshAt) else { return nil }
            guard boundaryRefreshAt <= normalRefreshDate else { return nil }
            guard snapshot.updatedAt < boundaryRefreshAt else { return nil }
            return ResetBoundaryRefreshCandidate(
                refreshAt: max(
                    boundaryRefreshAt,
                    now.addingTimeInterval(Self.resetBoundaryRefreshMinimumDelaySeconds)),
                boundaryRefreshAt: boundaryRefreshAt)
        }
    }
}

extension UsageSnapshot {
    fileprivate func allRateWindows() -> [RateWindow] {
        [self.primary, self.secondary, self.tertiary].compactMap(\.self) +
            (self.extraRateWindows?.map(\.window) ?? [])
    }
}
