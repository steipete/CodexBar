import CodexBarCore
import CryptoKit
import Foundation

@MainActor
extension UsageStore {
    private static let minimumPaceExpectedPercent: Double = 3
    private static let backfillMaxTimestampMismatch: TimeInterval = 5 * 60

    func weeklyPace(provider: UsageProvider, window: RateWindow, now: Date = .init()) -> UsagePace? {
        guard provider == .codex || provider == .claude else { return nil }
        guard window.remainingPercent > 0 else { return nil }
        let codexAccountKey = self.codexHistoricalAccountKey()

        let resolved: UsagePace? = if provider == .codex,
                                      self.settings.historicalTrackingEnabled,
                                      self.codexHistoricalDatasetAccountKey == codexAccountKey,
                                      let historical = CodexHistoricalPaceEvaluator.evaluate(
                                          window: window,
                                          now: now,
                                          dataset: self.codexHistoricalDataset)
        {
            historical
        } else {
            UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 10080)
        }

        guard let resolved else { return nil }
        guard resolved.expectedUsedPercent >= Self.minimumPaceExpectedPercent else { return nil }
        return resolved
    }

    func recordCodexHistoricalSampleIfNeeded(snapshot: UsageSnapshot) {
        guard self.settings.historicalTrackingEnabled else { return }
        guard let weekly = snapshot.secondary else { return }

        let sampledAt = snapshot.updatedAt
        let accountKey = self.codexHistoricalAccountKey(preferredEmail: snapshot.accountEmail(for: .codex))
        let historyStore = self.historicalUsageHistoryStore
        Task.detached(priority: .utility) { [weak self] in
            let dataset = await historyStore.recordCodexWeekly(
                window: weekly,
                sampledAt: sampledAt,
                accountKey: accountKey)
            await MainActor.run { [weak self] in
                self?.setCodexHistoricalDataset(dataset, accountKey: accountKey)
            }
        }
    }

    func refreshHistoricalDatasetIfNeeded() async {
        if !self.settings.historicalTrackingEnabled {
            self.setCodexHistoricalDataset(nil, accountKey: nil)
            return
        }
        let accountKey = self.codexHistoricalAccountKey(dashboard: self.openAIDashboard)
        let dataset = await self.historicalUsageHistoryStore.loadCodexDataset(accountKey: accountKey)
        self.setCodexHistoricalDataset(dataset, accountKey: accountKey)
        if let dashboard = self.openAIDashboard {
            self.backfillCodexHistoricalFromDashboardIfNeeded(dashboard)
        }
    }

    func backfillCodexHistoricalFromDashboardIfNeeded(_ dashboard: OpenAIDashboardSnapshot) {
        guard self.settings.historicalTrackingEnabled else { return }
        guard !dashboard.usageBreakdown.isEmpty else { return }

        let codexSnapshot = self.snapshots[.codex]
        let accountKey = self.codexHistoricalAccountKey(
            preferredEmail: codexSnapshot?.accountEmail(for: .codex),
            dashboard: dashboard)
        let referenceWindow: RateWindow
        let calibrationAt: Date
        if let dashboardWeekly = dashboard.secondaryLimit {
            referenceWindow = dashboardWeekly
            calibrationAt = dashboard.updatedAt
        } else if let codexSnapshot, let snapshotWeekly = codexSnapshot.secondary {
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
            let dataset = await historyStore.backfillCodexWeeklyFromUsageBreakdown(
                usageBreakdown,
                referenceWindow: referenceWindow,
                now: calibrationAt,
                accountKey: accountKey)
            await MainActor.run { [weak self] in
                self?.setCodexHistoricalDataset(dataset, accountKey: accountKey)
            }
        }
    }

    private func setCodexHistoricalDataset(_ dataset: CodexHistoricalDataset?, accountKey: String?) {
        self.codexHistoricalDataset = dataset
        self.codexHistoricalDatasetAccountKey = accountKey
        self.historicalPaceRevision += 1
    }

    private func codexHistoricalAccountKey(
        preferredEmail: String? = nil,
        dashboard: OpenAIDashboardSnapshot? = nil) -> String?
    {
        let sourceEmail = preferredEmail ??
            self.snapshots[.codex]?.accountEmail(for: .codex) ??
            dashboard?.signedInEmail ??
            self.codexAccountEmailForOpenAIDashboard()
        guard let sourceEmail else { return nil }
        let normalized = sourceEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        return Self.sha256Hex(normalized)
    }

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
