import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    private static let backfillMaxTimestampMismatch: TimeInterval = 5 * 60

    func weeklyPace(
        provider: UsageProvider,
        window: RateWindow,
        now: Date = .init(),
        minimumExpectedPercent: Double = 3,
        minimumElapsedPercent: Double? = nil) -> UsagePace?
    {
        guard window.remainingPercent > 0 else { return nil }
        let resolved: UsagePace?
        let elapsedWindow: RateWindow
        let workDays = self.settings.weeklyProgressWorkDays
        // Provider-specific by design: only Codex's dashboard yields an account-scoped daily curve for learned pace;
        // other providers use the generic linear window calculation.
        if provider == .codex, self.settings.historicalTrackingEnabled, workDays == nil {
            elapsedWindow = window
            let codexAccountKey = self.codexOwnershipContext().canonicalKey
            if self.codexHistoricalDatasetAccountKey == codexAccountKey,
               let historical = CodexHistoricalPaceEvaluator.evaluate(
                   window: window,
                   now: now,
                   dataset: self.codexHistoricalDataset)
            {
                resolved = historical
            } else {
                resolved = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 10080, workDays: workDays)
            }
            // Provider-specific by design: explicit Codex work-day scheduling keeps this branch on the
            // shared pace calculation while learned history remains disabled by the user's declared plan.
        } else if provider == .codex, self.settings.historicalTrackingEnabled {
            elapsedWindow = window
            // An explicit work-day schedule is the user's declared plan and takes precedence over learned history.
            // Keep collecting history in the background so Automatic can resume historical pacing immediately.
            resolved = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 10080, workDays: workDays)
        } else {
            // Generic providers must carry an explicit window duration. Using the 10080-minute fallback for
            // windows without windowMinutes would fabricate a weekly pace for non-weekly windows
            // (e.g. Factory monthly with only resetsAt).
            guard window.windowMinutes != nil else { return nil }
            // Expand a monthly sentinel to the real calendar cycle before scoring. The menu card and the
            // CLI both resolve first, so skipping it here would score a billing period as a flat 30 days
            // and disagree with them — and a 31-day cycle would exceed the sentinel outright, dropping the
            // pace for the first day of every long month.
            let paceWindow = self.paceWindowForElapsedEligibility(provider: provider, window: window)
            elapsedWindow = paceWindow
            resolved = UsagePace.weekly(window: paceWindow, now: now, defaultWindowMinutes: 10080, workDays: workDays)
        }

        guard let resolved else { return nil }
        let expectedFloorMet = resolved.expectedUsedPercent >= minimumExpectedPercent
        let elapsedFloorMet = minimumElapsedPercent.map { minimum in
            (Self.windowElapsedPercent(window: elapsedWindow, now: now) ?? 0) >= minimum
        } ?? false
        guard expectedFloorMet || elapsedFloorMet else { return nil }
        return resolved
    }

    /// Signed pace delta (`+11%`, `-8%`, `0%`) for a menu-bar layout pace token, or nil when the window
    /// carries no pace-capable metadata. Shared by the status item and the layout editor preview so both
    /// resolve pace through the same historical/work-day settings as the menu card.
    func menuBarLayoutPaceText(
        provider: UsageProvider,
        window: RateWindow?,
        now: Date = .init(),
        minimumExpectedPercent: Double = 3,
        minimumElapsedPercent: Double? = nil)
        -> String?
    {
        window
            .flatMap {
                self.weeklyPace(
                    provider: provider,
                    window: $0,
                    now: now,
                    minimumExpectedPercent: minimumExpectedPercent,
                    minimumElapsedPercent: minimumElapsedPercent)
            }
            .flatMap { MenuBarDisplayText.paceText(pace: $0) }
    }

    /// Numeric twin of `menuBarLayoutPaceText`, rounded to whole percentage points like the text so a
    /// conditional predicate always compares exactly the value the menu bar shows.
    func menuBarLayoutPaceDelta(
        provider: UsageProvider,
        window: RateWindow?,
        now: Date = .init(),
        minimumExpectedPercent: Double = 3,
        minimumElapsedPercent: Double? = nil)
        -> Double?
    {
        window
            .flatMap {
                self.weeklyPace(
                    provider: provider,
                    window: $0,
                    now: now,
                    minimumExpectedPercent: minimumExpectedPercent,
                    minimumElapsedPercent: minimumElapsedPercent)
            }
            .map { $0.deltaPercent.rounded() }
    }

    /// A learned Codex curve can stay flat near the start of a weekly window even as the window
    /// itself advances. The weekly menu token uses elapsed progress as an eligibility fallback,
    /// while the returned pace still retains the learned expected-use value.
    func paceWindowForElapsedEligibility(provider: UsageProvider, window: RateWindow) -> RateWindow {
        // Provider-specific by design: Codex's consumer projection already resolves its historical window.
        guard provider != .codex, window.windowMinutes != nil else { return window }
        return ProviderDescriptorRegistry.descriptor(for: provider)
            .pace
            .resolvedResetWindowForPace(window)
    }

    nonisolated static func paceElapsedBoundary(
        window: RateWindow,
        minimumElapsedPercent: Double) -> Date?
    {
        guard minimumElapsedPercent > 0,
              let resetsAt = window.resetsAt,
              let windowMinutes = window.windowMinutes,
              windowMinutes > 0
        else { return nil }
        let duration = TimeInterval(windowMinutes) * 60
        let start = resetsAt.addingTimeInterval(-duration)
        return start.addingTimeInterval(duration * minimumElapsedPercent / 100)
    }

    private static func windowElapsedPercent(window: RateWindow, now: Date) -> Double? {
        guard let resetsAt = window.resetsAt,
              let windowMinutes = window.windowMinutes,
              windowMinutes > 0
        else { return nil }
        let duration = TimeInterval(windowMinutes) * 60
        let start = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(start)
        return min(100, max(0, elapsed / duration * 100))
    }

    func recordCodexHistoricalSampleIfNeeded(snapshot: UsageSnapshot) {
        guard self.settings.historicalTrackingEnabled else { return }
        let projection = self.codexConsumerProjection(
            surface: .liveCard,
            snapshotOverride: snapshot,
            now: snapshot.updatedAt)
        guard let weekly = projection.rateWindow(for: .weekly) else { return }

        let sampledAt = snapshot.updatedAt
        let ownership = self.codexOwnershipContext(preferredEmail: snapshot.accountEmail(for: .codex))
        let historyStore = self.historicalUsageHistoryStore
        Task.detached(priority: .utility) { [weak self] in
            _ = await historyStore.recordCodexWeekly(
                window: weekly,
                sampledAt: sampledAt,
                accountKey: ownership.canonicalKey)
            let dataset = await historyStore.loadCodexDataset(
                canonicalAccountKey: ownership.canonicalKey,
                canonicalEmailHashKey: ownership.canonicalEmailHashKey,
                legacyEmailHash: ownership.historicalLegacyEmailHash,
                hasAdjacentMultiAccountVeto: ownership.hasAdjacentMultiAccountVeto)
            await MainActor.run { [weak self] in
                self?.setCodexHistoricalDataset(dataset, accountKey: ownership.canonicalKey)
            }
        }
    }

    func refreshHistoricalDatasetIfNeeded() async {
        if !self.settings.historicalTrackingEnabled {
            self.setCodexHistoricalDataset(nil, accountKey: nil)
            return
        }
        let ownership = self.codexOwnershipContext()
        let dataset = await self.historicalUsageHistoryStore.loadCodexDataset(
            canonicalAccountKey: ownership.canonicalKey,
            canonicalEmailHashKey: ownership.canonicalEmailHashKey,
            legacyEmailHash: ownership.historicalLegacyEmailHash,
            hasAdjacentMultiAccountVeto: ownership.hasAdjacentMultiAccountVeto)
        self.setCodexHistoricalDataset(dataset, accountKey: ownership.canonicalKey)
        if let dashboard = self.openAIDashboard {
            let authority = self.evaluateCodexDashboardAuthority(
                dashboard: dashboard,
                sourceKind: .liveWeb,
                routingTargetEmail: self.lastOpenAIDashboardTargetEmail)
            self.backfillCodexHistoricalFromDashboardIfNeeded(
                dashboard,
                authorityDecision: authority.decision,
                attachedAccountEmail: self.codexDashboardAttachmentEmail(from: authority.input))
        }
    }

    func backfillCodexHistoricalFromDashboardIfNeeded(
        _ dashboard: OpenAIDashboardSnapshot,
        authorityDecision: CodexDashboardAuthorityDecision,
        attachedAccountEmail: String?)
    {
        guard self.settings.historicalTrackingEnabled else { return }
        guard authorityDecision.allowedEffects.contains(.historicalBackfill) else { return }
        let usageBreakdown = OpenAIDashboardDailyBreakdown.removingSkillUsageServices(
            from: dashboard.usageBreakdown)
        guard !usageBreakdown.isEmpty else { return }

        let codexSnapshot = self.snapshots[.codex]
        let ownership = self.codexOwnershipContext(preferredEmail: attachedAccountEmail)
        let referenceWindow: RateWindow
        let calibrationAt: Date
        if let dashboardWeekly = CodexReconciledState.fromAttachedDashboard(
            snapshot: dashboard,
            provider: .codex,
            accountEmail: attachedAccountEmail,
            accountPlan: nil)?
            .weekly
        {
            referenceWindow = dashboardWeekly
            calibrationAt = dashboard.updatedAt
        } else if let codexSnapshot,
                  let snapshotWeekly = self.codexConsumerProjection(
                      surface: .liveCard,
                      snapshotOverride: codexSnapshot,
                      now: codexSnapshot.updatedAt).rateWindow(for: .weekly)
        {
            let mismatch = abs(codexSnapshot.updatedAt.timeIntervalSince(dashboard.updatedAt))
            guard mismatch <= Self.backfillMaxTimestampMismatch else { return }
            referenceWindow = snapshotWeekly
            calibrationAt = min(codexSnapshot.updatedAt, dashboard.updatedAt)
        } else {
            return
        }

        let historyStore = self.historicalUsageHistoryStore
        Task.detached(priority: .utility) { [weak self] in
            _ = await historyStore.backfillCodexWeeklyFromUsageBreakdown(
                usageBreakdown,
                referenceWindow: referenceWindow,
                now: calibrationAt,
                accountKey: ownership.canonicalKey)
            let dataset = await historyStore.loadCodexDataset(
                canonicalAccountKey: ownership.canonicalKey,
                canonicalEmailHashKey: ownership.canonicalEmailHashKey,
                legacyEmailHash: ownership.historicalLegacyEmailHash,
                hasAdjacentMultiAccountVeto: ownership.hasAdjacentMultiAccountVeto)
            await MainActor.run { [weak self] in
                self?.setCodexHistoricalDataset(dataset, accountKey: ownership.canonicalKey)
            }
        }
    }

    private func setCodexHistoricalDataset(_ dataset: CodexHistoricalDataset?, accountKey: String?) {
        self.codexHistoricalDataset = dataset
        self.codexHistoricalDatasetAccountKey = accountKey
        self.historicalPaceRevision += 1
    }
}
