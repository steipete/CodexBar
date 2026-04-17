import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func supportsWeeklyPace(for provider: UsageProvider) -> Bool {
        switch provider {
        case .codex, .claude, .opencode, .abacus:
            true
        default:
            false
        }
    }

    private static let minimumPaceExpectedPercent: Double = 3
    private static let backfillMaxTimestampMismatch: TimeInterval = 5 * 60

    func weeklyPace(provider: UsageProvider, window: RateWindow, now: Date = .init()) -> UsagePace? {
        guard self.supportsWeeklyPace(for: provider) else { return nil }
        guard window.remainingPercent > 0 else { return nil }
        let resolved: UsagePace?
        if provider == .codex, self.settings.historicalTrackingEnabled {
            let codexAccountKey = self.codexOwnershipContext().canonicalKey
            if self.codexHistoricalDatasetAccountKey == codexAccountKey,
               let historical = CodexHistoricalPaceEvaluator.evaluate(
                   window: window,
                   now: now,
                   dataset: self.codexHistoricalDataset)
            {
                resolved = historical
            } else {
                resolved = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 10080)
            }
        } else {
            resolved = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 10080)
        }

        guard let resolved else { return nil }
        guard resolved.expectedUsedPercent >= Self.minimumPaceExpectedPercent else { return nil }
        return resolved
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
        guard !dashboard.usageBreakdown.isEmpty else { return }

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
        let usageBreakdown = dashboard.usageBreakdown
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
