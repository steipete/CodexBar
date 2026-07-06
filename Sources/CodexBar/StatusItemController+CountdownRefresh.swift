import CodexBarCore
import Foundation

extension StatusItemController {
    private nonisolated static let menuBarCountdownRefreshEpsilon: TimeInterval = 0.05

    func scheduleMenuBarCountdownRefreshIfNeeded(now: Date = .init()) {
        self.menuBarCountdownRefreshTask?.cancel()
        self.menuBarCountdownRefreshTask = nil

        var delays: [TimeInterval] = []
        let providers = self.menuBarRefreshProviders()
        if self.settings.menuBarShowsBrandIconWithPercent,
           self.settings.menuBarDisplayMode == .resetTime,
           self.settings.resetTimeDisplayStyle == .countdown
        {
            let resetDates = providers.compactMap { provider in
                self.menuBarMetricWindow(
                    for: provider,
                    snapshot: self.store.snapshot(for: provider),
                    now: now)?.resetsAt
            }
            if let delay = Self.menuBarCountdownRefreshDelay(resetDates: resetDates, now: now) {
                delays.append(delay)
            }
        }

        if self.menuBarObservesCodexReset(providers: providers) {
            let projection = self.store.codexConsumerProjection(surface: .menuBar, now: now)
            if let resetAt = projection.nextMenuBarStateChangeAt {
                delays.append(max(
                    Self.menuBarCountdownRefreshEpsilon,
                    resetAt.timeIntervalSince(now) + Self.menuBarCountdownRefreshEpsilon))
            }
        }
        guard let delay = delays.min() else { return }

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

    private func menuBarRefreshProviders() -> [UsageProvider] {
        if self.shouldMergeIcons {
            return [self.primaryProviderForUnifiedIcon()]
        }
        return UsageProvider.allCases.filter(self.isVisible)
    }

    private func menuBarObservesCodexReset(providers: [UsageProvider]) -> Bool {
        if providers.contains(.codex) { return true }
        guard self.shouldMergeIcons, self.settings.menuBarShowsHighestUsage else { return false }
        let activeProviders = self.store.enabledProvidersForDisplay()
        return self.settings.resolvedMergedOverviewProviders(
            activeProviders: activeProviders,
            maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit).contains(.codex)
    }

    #if DEBUG
    func _test_isMenuBarCountdownRefreshScheduled() -> Bool {
        self.menuBarCountdownRefreshTask != nil
    }
    #endif
}
