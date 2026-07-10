import CodexBarCore
import Foundation

extension StatusItemController {
    private nonisolated static let menuBarCountdownRefreshEpsilon: TimeInterval = 0.05

    func scheduleMenuBarCountdownRefreshIfNeeded(now: Date = .init()) {
        self.menuBarCountdownRefreshTask?.cancel()
        self.menuBarCountdownRefreshTask = nil

        var delays: [TimeInterval] = []
        let providers = self.menuBarRefreshProviders()
        let displayMode = self.settings.menuBarDisplayMode
        let smartExhaustedActive = self.settings.menuBarShowsBrandIconWithPercent
            && self.settings.menuBarShowsResetTimeWhenExhausted
            && displayMode != .resetTime

        /// Reset dates for every lane whose menu-bar text is currently a reset time — including both
        /// combined session/weekly lanes when the smart option surfaces reset text for each of them.
        func resetDrivenResetDates() -> [Date] {
            providers.flatMap { self.menuBarDisplayedResetDates(for: $0, now: now) }
        }

        if self.settings.menuBarShowsBrandIconWithPercent,
           self.settings.resetTimeDisplayStyle == .countdown,
           displayMode == .resetTime || smartExhaustedActive
        {
            // Countdown text ticks every minute; refresh on each displayed-minute boundary (the last of
            // which lands at the reset, flipping a smart-exhausted lane back to the percentage).
            if let delay = Self.menuBarCountdownRefreshDelay(resetDates: resetDrivenResetDates(), now: now) {
                delays.append(delay)
            }
        } else if smartExhaustedActive, self.settings.resetTimeDisplayStyle == .absolute {
            // Absolute clocks don't tick, so the per-minute scheduler above is skipped — but a smart
            // exhausted lane still needs one refresh at the reset boundary to fall back to the percentage
            // once the reset passes (otherwise a slow/manual provider refresh leaves a stale past clock).
            for resetsAt in resetDrivenResetDates() {
                let remaining = resetsAt.timeIntervalSince(now)
                if remaining > 0 {
                    delays.append(remaining + Self.menuBarCountdownRefreshEpsilon)
                }
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
