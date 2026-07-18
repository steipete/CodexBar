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

        var countdownResetDates: [Date] = []
        var absoluteResetDates: [Date] = []
        for provider in providers {
            let resetDates = self.menuBarDisplayedResetDates(for: provider, now: now)
            let resolution = self.settings.menuBarLayoutResolution(for: provider)
            if !resolution.usesLegacyRendering,
               self.settings.menuBarIconStyle == .iconAndPercent
            {
                let tokens = resolution.layout.lines.joined()
                if tokens.contains(.resetCountdown) {
                    countdownResetDates.append(contentsOf: resetDates)
                }
                if tokens.contains(.resetAbsolute) {
                    absoluteResetDates.append(contentsOf: resetDates)
                }
                continue
            }

            guard self.settings.menuBarShowsBrandIconWithPercent,
                  displayMode == .resetTime || smartExhaustedActive
            else { continue }
            switch self.settings.resetTimeDisplayStyle {
            case .countdown:
                countdownResetDates.append(contentsOf: resetDates)
            case .absolute:
                absoluteResetDates.append(contentsOf: resetDates)
            }
        }

        if let delay = Self.menuBarCountdownRefreshDelay(resetDates: countdownResetDates, now: now) {
            // Countdown text ticks every minute; refresh on each displayed-minute boundary (the last of
            // which lands at the reset, flipping a smart-exhausted lane back to the percentage).
            delays.append(delay)
        }
        if let delay = Self.menuBarAbsoluteRefreshDelay(resetDates: absoluteResetDates, now: now) {
            // Absolute clocks don't tick each minute, but their human-friendly date label can change at
            // local midnight (for example, "tomorrow" becomes a same-day time). Wake at that boundary or
            // the reset itself, whichever comes first; the next icon update schedules any later boundary.
            delays.append(delay)
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

    nonisolated static func menuBarAbsoluteRefreshDelay(
        resetDates: [Date],
        now: Date,
        calendar: Calendar = .current)
        -> TimeInterval?
    {
        guard let nextDayStart = calendar.dateInterval(of: .day, for: now)?.end else { return nil }

        return resetDates.compactMap { resetDate -> TimeInterval? in
            guard resetDate > now else { return nil }
            let nextTextChange = min(resetDate, nextDayStart)
            return max(
                self.menuBarCountdownRefreshEpsilon,
                nextTextChange.timeIntervalSince(now) + self.menuBarCountdownRefreshEpsilon)
        }.min()
    }

    private func menuBarRefreshProviders() -> [UsageProvider] {
        if self.shouldMergeIcons {
            return [self.primaryProviderForUnifiedIcon()]
        }
        return UsageProvider.allCases.filter(self.isVisible)
    }

    private func menuBarObservesCodexReset(providers: [UsageProvider]) -> Bool {
        if providers.contains(.codex) {
            return true
        }
        guard self.shouldMergeIcons, self.settings.menuBarShowsHighestUsage else {
            return false
        }
        let activeProviders = self.store.enabledProvidersForDisplay()
        return self.settings.resolvedMergedOverviewProviders(
            activeProviders: activeProviders,
            maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit).contains(.codex)
    }

    func observeMenuBarTimeEnvironmentChanges() {
        for name in [
            Notification.Name.NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
            .NSCalendarDayChanged,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.handleMenuBarTimeEnvironmentDidChange),
                name: name,
                object: nil)
        }
    }

    @objc nonisolated func handleMenuBarTimeEnvironmentDidChange() {
        Task { @MainActor [weak self] in
            guard let self, !self.hasPreparedForAppShutdown else { return }
            self.handleMenuBarTimeEnvironmentChange()
        }
    }

    func handleMenuBarTimeEnvironmentChange() {
        self.updateIcons()
    }

    #if DEBUG
    func _test_isMenuBarCountdownRefreshScheduled() -> Bool {
        self.menuBarCountdownRefreshTask != nil
    }
    #endif
}
