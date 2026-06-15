import CodexBarCore
import Foundation

extension StatusItemController {
    private nonisolated static let menuBarCountdownRefreshEpsilon: TimeInterval = 0.05

    func scheduleMenuBarCountdownRefreshIfNeeded(now: Date = .init()) {
        self.menuBarCountdownRefreshTask?.cancel()
        self.menuBarCountdownRefreshTask = nil

        guard self.settings.menuBarShowsBrandIconWithPercent,
              self.settings.menuBarDisplayMode == .resetTime || self.settings.menuBarDisplayMode == .allMetrics
        else {
            return
        }
        guard self.menuBarDisplayNeedsCountdownRefresh() else { return }

        let resetDates = self.menuBarCountdownProviders().flatMap { provider in
            self.menuBarCountdownResetDates(for: provider)
        }
        guard let delay = Self.menuBarCountdownRefreshDelay(resetDates: resetDates, now: now) else {
            return
        }

        self.menuBarCountdownRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.menuBarCountdownRefreshTask = nil
            self.updateIcons()
        }
    }

    nonisolated static func menuBarCountdownRefreshDelay(
        resetDates: [Date],
        now: Date)
        -> TimeInterval?
    {
        resetDates.compactMap { resetDate -> TimeInterval? in
            let remaining = resetDate.timeIntervalSince(now)
            guard remaining > 0 else { return nil }
            let displayedMinutes = ceil(remaining / 60)
            let nextBoundaryRemaining = max(0, displayedMinutes - 1) * 60
            return max(
                self.menuBarCountdownRefreshEpsilon,
                remaining - nextBoundaryRemaining + self.menuBarCountdownRefreshEpsilon)
        }.min()
    }

    private func menuBarCountdownProviders() -> [UsageProvider] {
        if self.shouldMergeIcons {
            return [self.primaryProviderForUnifiedIcon()]
        }
        return UsageProvider.allCases.filter(self.isVisible)
    }

    private func menuBarCountdownResetDates(for provider: UsageProvider) -> [Date] {
        let snapshot = self.store.snapshot(for: provider)
        if self.settings.menuBarDisplayMode == .allMetrics {
            guard provider == .codex,
                  let projection = self.store.codexConsumerProjectionIfNeeded(
                      for: provider,
                      surface: .menuBar,
                      snapshotOverride: snapshot),
                  let reset = projection.rateWindow(for: .weekly)?.resetsAt
            else {
                return []
            }
            return [reset]
        }
        return self.menuBarMetricWindow(for: provider, snapshot: snapshot).flatMap(\.resetsAt).map { [$0] } ?? []
    }

    private func menuBarDisplayNeedsCountdownRefresh() -> Bool {
        switch self.settings.menuBarDisplayMode {
        case .resetTime:
            self.settings.resetTimeDisplayStyle == .countdown
        case .allMetrics:
            self.settings.codexAllMetricsShowsReset &&
                self.settings.codexAllMetricsResetFormat.usesCountdown(
                    globalStyle: self.settings.resetTimeDisplayStyle)
        case .percent, .pace, .both:
            false
        }
    }

    #if DEBUG
    func _test_isMenuBarCountdownRefreshScheduled() -> Bool {
        self.menuBarCountdownRefreshTask != nil
    }
    #endif
}
