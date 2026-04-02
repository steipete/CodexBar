import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    private static let minimumPaceExpectedPercent: Double = 3
    private static let backfillMaxTimestampMismatch: TimeInterval = 5 * 60

    private struct CodexHistoricalOwnershipContext: Sendable {
        let canonicalKey: String?
        let canonicalEmailHashKey: String?
        let legacyEmailHash: String?
        let hasAdjacentMultiAccountVeto: Bool
    }

    func weeklyPace(provider: UsageProvider, window: RateWindow, now: Date = .init()) -> UsagePace? {
        guard provider == .codex || provider == .claude || provider == .opencode else { return nil }
        guard window.remainingPercent > 0 else { return nil }
        let resolved: UsagePace?
        if provider == .codex, self.settings.historicalTrackingEnabled {
            let codexAccountKey = self.codexHistoricalOwnershipContext().canonicalKey
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
        guard let weekly = snapshot.secondary else { return }

        let sampledAt = snapshot.updatedAt
        let ownership = self.codexHistoricalOwnershipContext(preferredEmail: snapshot.accountEmail(for: .codex))
        let historyStore = self.historicalUsageHistoryStore
        Task.detached(priority: .utility) { [weak self] in
            _ = await historyStore.recordCodexWeekly(
                window: weekly,
                sampledAt: sampledAt,
                accountKey: ownership.canonicalKey)
            let dataset = await historyStore.loadCodexDataset(
                canonicalAccountKey: ownership.canonicalKey,
                canonicalEmailHashKey: ownership.canonicalEmailHashKey,
                legacyEmailHash: ownership.legacyEmailHash,
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
        let ownership = self.codexHistoricalOwnershipContext(dashboard: self.openAIDashboard)
        let dataset = await self.historicalUsageHistoryStore.loadCodexDataset(
            canonicalAccountKey: ownership.canonicalKey,
            canonicalEmailHashKey: ownership.canonicalEmailHashKey,
            legacyEmailHash: ownership.legacyEmailHash,
            hasAdjacentMultiAccountVeto: ownership.hasAdjacentMultiAccountVeto)
        self.setCodexHistoricalDataset(dataset, accountKey: ownership.canonicalKey)
        if let dashboard = self.openAIDashboard {
            self.backfillCodexHistoricalFromDashboardIfNeeded(dashboard)
        }
    }

    func backfillCodexHistoricalFromDashboardIfNeeded(_ dashboard: OpenAIDashboardSnapshot) {
        guard self.settings.historicalTrackingEnabled else { return }
        guard !dashboard.usageBreakdown.isEmpty else { return }

        let codexSnapshot = self.snapshots[.codex]
        let ownership = self.codexHistoricalOwnershipContext(
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
            _ = await historyStore.backfillCodexWeeklyFromUsageBreakdown(
                usageBreakdown,
                referenceWindow: referenceWindow,
                now: calibrationAt,
                accountKey: ownership.canonicalKey)
            let dataset = await historyStore.loadCodexDataset(
                canonicalAccountKey: ownership.canonicalKey,
                canonicalEmailHashKey: ownership.canonicalEmailHashKey,
                legacyEmailHash: ownership.legacyEmailHash,
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

    private func codexHistoricalOwnershipContext(
        preferredEmail: String? = nil,
        dashboard: OpenAIDashboardSnapshot? = nil) -> CodexHistoricalOwnershipContext
    {
        let resolvedIdentity = self.currentCodexRuntimeIdentity(
            source: self.settings.codexResolvedActiveSource,
            preferCurrentSnapshot: true,
            allowLastKnownLiveFallback: true)
        let activeSourceEmail = self.codexAccountScopedRefreshEmail(
            preferCurrentSnapshot: true,
            allowLastKnownLiveFallback: true)
        let normalizedEmail = CodexIdentityResolver.normalizeEmail(
            preferredEmail ??
                activeSourceEmail ??
                self.snapshots[.codex]?.accountEmail(for: .codex) ??
                dashboard?.signedInEmail ??
                self.codexAccountEmailForOpenAIDashboard())
        let canonicalIdentity: CodexIdentity = switch resolvedIdentity {
        case .unresolved:
            if let normalizedEmail {
                .emailOnly(normalizedEmail: normalizedEmail)
            } else {
                .unresolved
            }
        default:
            resolvedIdentity
        }
        let emailForLegacyHash: String? = switch canonicalIdentity {
        case let .emailOnly(normalizedEmail):
            normalizedEmail
        case .providerAccount, .unresolved:
            normalizedEmail
        }
        return CodexHistoricalOwnershipContext(
            canonicalKey: CodexHistoryOwnership.canonicalKey(for: canonicalIdentity),
            canonicalEmailHashKey: normalizedEmail.map { CodexHistoryOwnership.canonicalEmailHashKey(for: $0) },
            legacyEmailHash: emailForLegacyHash.map { CodexHistoryOwnership.legacyEmailHash(normalizedEmail: $0) },
            hasAdjacentMultiAccountVeto: self.codexHistoricalHasAdjacentMultiAccountVeto())
    }

    private func codexHistoricalHasAdjacentMultiAccountVeto() -> Bool {
        let snapshot = self.settings.codexAccountReconciliationSnapshot
        var distinctAccounts: Set<String> = []

        if let activeManagedAccount = self.settings.activeManagedCodexAccount {
            distinctAccounts.insert(CodexIdentityMatcher.selectionKey(
                for: snapshot.runtimeIdentity(for: activeManagedAccount),
                fallbackEmail: snapshot.runtimeEmail(for: activeManagedAccount)))
        }

        if let liveSystemAccount = snapshot.liveSystemAccount {
            distinctAccounts.insert(CodexIdentityMatcher.selectionKey(
                for: snapshot.runtimeIdentity(for: liveSystemAccount),
                fallbackEmail: liveSystemAccount.email))
        }

        return distinctAccounts.count > 1
    }
}
