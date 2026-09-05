import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    nonisolated static let codexSnapshotWaitTimeoutSeconds: TimeInterval = 6
    nonisolated static let codexRefreshStartGraceSeconds: TimeInterval = 0.25
    nonisolated static let codexSnapshotPollIntervalNanoseconds: UInt64 = 100_000_000

    func codexCreditsFetcher() -> UsageFetcher {
        // Credits are remote Codex account state, so they need the same managed-home routing as the
        // primary Codex usage fetch. Token-cost scanning owns its selected managed or ambient scope separately.
        self.makeFetchContext(provider: .codex, override: nil).fetcher
    }

    func scheduleCreditsRefreshIfNeeded(minimumSnapshotUpdatedAt: Date? = nil) {
        let refreshKey = self.codexCreditsRefreshKey(
            expectedGuard: self.freshCodexAccountScopedRefreshGuard())
        if let existing = self.creditsRefreshTask,
           !existing.isCancelled,
           self.creditsRefreshTaskKey == refreshKey
        {
            return
        }

        self.creditsRefreshTask?.cancel()
        self.creditsRefreshTaskKey = refreshKey
        self.creditsRefreshTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.creditsRefreshTaskKey == refreshKey {
                    self.creditsRefreshTask = nil
                    self.creditsRefreshTaskKey = nil
                }
            }
            await self.refreshCreditsIfNeeded(minimumSnapshotUpdatedAt: minimumSnapshotUpdatedAt)
            guard !Task.isCancelled else { return }
            self.persistWidgetSnapshot(reason: "credits")
        }
    }

    func cancelScheduledCreditsRefresh() {
        self.creditsRefreshTask?.cancel()
        self.creditsRefreshTask = nil
        self.creditsRefreshTaskKey = nil
    }

    func refreshCreditsNow(minimumSnapshotUpdatedAt: Date? = nil) async {
        self.cancelScheduledCreditsRefresh()
        await self.refreshCreditsIfNeeded(minimumSnapshotUpdatedAt: minimumSnapshotUpdatedAt)
    }

    func codexCreditsRefreshKey(expectedGuard: CodexAccountScopedRefreshGuard) -> String {
        let sourceKey = switch expectedGuard.source {
        case .liveSystem:
            "live"
        case let .managedAccount(id):
            "managed:\(id.uuidString)"
        case let .profileHome(path):
            "profile:\(path)"
        }

        let identityKey = switch expectedGuard.identity {
        case let .providerAccount(id):
            "provider:\(id)"
        case let .emailOnly(normalizedEmail):
            "email:\(normalizedEmail)"
        case .unresolved:
            "unresolved"
        }

        return [
            sourceKey,
            identityKey,
            expectedGuard.accountKey ?? "account:nil",
            "auth:\(expectedGuard.authFingerprint ?? "nil")",
        ].joined(separator: "|")
    }

    func refreshCreditsIfNeeded(minimumSnapshotUpdatedAt: Date? = nil) async {
        guard self.isEnabled(.codex) else { return }
        var expectedGuard = self.freshCodexAccountScopedRefreshGuard()
        if expectedGuard.identity == .unresolved,
           let minimumSnapshotUpdatedAt,
           case .liveSystem = expectedGuard.source
        {
            _ = await self.waitForCodexSnapshotOrRefreshCompletion(minimumUpdatedAt: minimumSnapshotUpdatedAt)
            expectedGuard = self.freshCodexAccountScopedRefreshGuard()
        }
        guard expectedGuard.identity != .unresolved,
              expectedGuard.accountKey != nil
        else {
            return
        }
        do {
            let credits = try await self.loadLatestCodexCredits(expectedGuard: expectedGuard)
            guard !Task.isCancelled else { return }
            guard let applyGuard = self.codexScopedNonUsageSuccessApplyGuard(
                expectedGuard: expectedGuard) else { return }
            self.reconcileCodexPublishedUsageOwner(with: applyGuard)
            await MainActor.run {
                self.credits = credits
                self.lastCreditsError = nil
                self.lastCreditsSnapshot = credits
                self.lastCreditsSnapshotAccountKey = applyGuard.accountKey
                self.lastCreditsSnapshotOwnerGuard = applyGuard
                self.lastCreditsSource = credits == nil ? .none : .api
                self.creditsFailureStreak = 0
                self.lastCodexAccountScopedRefreshGuard = applyGuard
                self.persistPublishedCodexCreditsIntoAccountSnapshotsIfNeeded()
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
            guard !Task.isCancelled else { return }
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("data not available yet") {
                guard self.shouldApplyCodexScopedNonUsageFailure(expectedGuard: expectedGuard) else { return }
                self.reconcileCodexPublishedUsageOwner(with: expectedGuard)
                await MainActor.run {
                    if let cached = self.lastCreditsSnapshot,
                       let cachedOwnerGuard = self.lastCreditsSnapshotOwnerGuard,
                       Self.codexScopedRefreshGuardsMatchAccount(cachedOwnerGuard, expectedGuard)
                    {
                        self.credits = cached
                        self.lastCreditsError = nil
                        self.lastCodexAccountScopedRefreshGuard = expectedGuard
                    } else {
                        self.credits = nil
                        self.lastCreditsSource = .none
                        self.lastCreditsError = L("Codex credits are still loading; will retry shortly.")
                    }
                }
                return
            }

            guard self.shouldApplyCodexScopedNonUsageFailure(expectedGuard: expectedGuard) else { return }
            self.reconcileCodexPublishedUsageOwner(with: expectedGuard)
            await MainActor.run {
                self.creditsFailureStreak += 1
                if let cached = self.lastCreditsSnapshot,
                   let cachedOwnerGuard = self.lastCreditsSnapshotOwnerGuard,
                   Self.codexScopedRefreshGuardsMatchAccount(cachedOwnerGuard, expectedGuard)
                {
                    self.credits = cached
                    let stamp = cached.updatedAt.formatted(date: .abbreviated, time: .shortened)
                    self.lastCreditsError =
                        "Last Codex credits refresh failed: \(message). Cached values from \(stamp)."
                    self.lastCodexAccountScopedRefreshGuard = expectedGuard
                } else {
                    self.lastCreditsError = message
                    self.credits = nil
                    self.lastCreditsSource = .none
                }
            }
        }
    }

    private func loadLatestCodexCredits(
        expectedGuard: CodexAccountScopedRefreshGuard) async throws -> CreditsSnapshot?
    {
        if let override = self._test_codexCreditsLoaderOverride {
            return try await override()
        }
        let descriptor = self.providerSpecs[.codex]?.descriptor ?? ProviderDescriptorRegistry.descriptor(for: .codex)
        let context = self.makeFetchContext(provider: .codex, override: nil, includeCredits: true)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        var lastAvailableError: Error?
        let prior = await MainActor.run { () -> CreditsSnapshot? in
            guard let cachedOwnerGuard = self.lastCreditsSnapshotOwnerGuard,
                  Self.codexScopedRefreshGuardsMatchAccount(cachedOwnerGuard, expectedGuard)
            else {
                return nil
            }
            return self.lastCreditsSnapshot
        }

        strategyLoop: for strategy in strategies {
            guard await strategy.isAvailable(context) else { continue }
            do {
                let result = try await strategy.fetch(context)
                switch CodexMonthlyCreditPreservation.standaloneRefreshOutcome(
                    incoming: result.credits,
                    prior: prior,
                    enrichmentFailed: result.codexMonthlyLimitEnrichmentFailed)
                {
                case let .published(credits):
                    return credits
                case .notFound:
                    lastAvailableError = UsageError.noRateLimitsFound
                    guard context.sourceMode == .auto else { break strategyLoop }
                }
            } catch {
                lastAvailableError = error
                guard strategy.shouldFallback(on: error, context: context) else { break strategyLoop }
            }
        }
        throw lastAvailableError ?? ProviderFetchError.noAvailableStrategy(.codex)
    }

    func waitForCodexSnapshot(minimumUpdatedAt: Date) async -> UsageSnapshot? {
        let deadline = Date().addingTimeInterval(Self.codexSnapshotWaitTimeoutSeconds)

        while Date() < deadline {
            if Task.isCancelled {
                return nil
            }
            if let snapshot = await MainActor.run(body: { self.snapshots[.codex] }),
               snapshot.updatedAt >= minimumUpdatedAt
            {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: Self.codexSnapshotPollIntervalNanoseconds)
        }

        return nil
    }

    func waitForCodexSnapshotOrRefreshCompletion(minimumUpdatedAt: Date) async -> UsageSnapshot? {
        let deadline = Date().addingTimeInterval(Self.codexSnapshotWaitTimeoutSeconds)
        let refreshStartDeadline = Date().addingTimeInterval(Self.codexRefreshStartGraceSeconds)

        while Date() < deadline {
            if Task.isCancelled {
                return nil
            }
            let state = await MainActor.run {
                (
                    snapshot: self.snapshots[.codex],
                    isRefreshing: self.refreshingProviders.contains(.codex),
                    hasAttempts: !(self.lastFetchAttempts[.codex] ?? []).isEmpty,
                    hasError: self.errors[.codex] != nil)
            }
            if let snapshot = state.snapshot, snapshot.updatedAt >= minimumUpdatedAt {
                return snapshot
            }
            if !state.isRefreshing, state.hasAttempts || state.hasError {
                return nil
            }
            if !state.isRefreshing,
               !state.hasAttempts,
               !state.hasError,
               Date() >= refreshStartDeadline
            {
                return nil
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

    func publishHydratedCodexCreditsIfNeeded(
        from persistedCredits: CreditsSnapshot?,
        ownerGuard: CodexAccountScopedRefreshGuard)
    {
        guard let credits = CodexMonthlyCreditPreservation.hydrationCredits(
            existingCredits: self.credits,
            persistedCredits: persistedCredits)
        else { return }
        self.credits = credits
        self.lastCreditsError = nil
        self.lastCreditsSnapshot = credits
        self.lastCreditsSnapshotAccountKey = ownerGuard.accountKey
        self.lastCreditsSnapshotOwnerGuard = ownerGuard
        self.lastCreditsSource = .api
    }

    func shouldPublishSelectedCodexCredits(
        _ result: ProviderFetchResult,
        publishedCredits: CreditsSnapshot?,
        publicationGuard: CodexAccountScopedRefreshGuard) -> Bool
    {
        let ownerMatches = self.lastCreditsSnapshotOwnerGuard.map {
            Self.codexScopedRefreshGuardsMatchAccount($0, publicationGuard)
        } ?? false
        let cachedCredits = ownerMatches
            ? self.lastCreditsSnapshot
            : nil
        let currentCredits = ownerMatches
            ? self.credits
            : nil
        return CodexMonthlyCreditPreservation.shouldPublishSelectedCredits(
            enrichmentFailed: result.codexMonthlyLimitEnrichmentFailed,
            publishedCredits: publishedCredits,
            currentCredits: currentCredits,
            cachedCredits: cachedCredits)
    }

    func persistPublishedCodexCreditsIntoAccountSnapshotsIfNeeded() {
        guard let refreshGuard = self.lastCreditsSnapshotOwnerGuard,
              let accountKey = refreshGuard.accountKey
        else { return }
        var matches = self.codexAccountSnapshots.indices.filter { index in
            Self.codexAccountSnapshot(
                self.codexAccountSnapshots[index],
                matchesPublishedCreditsAccountKey: accountKey,
                refreshGuard: refreshGuard)
        }
        if matches.count > 1,
           let activeID = self.settings.codexVisibleAccountProjection.activeVisibleAccountID
        {
            matches = matches.filter { self.codexAccountSnapshots[$0].id == activeID }
        }
        guard matches.count == 1, let index = matches.first else { return }
        let row = self.codexAccountSnapshots[index]
        self.codexAccountSnapshots[index] = CodexAccountUsageSnapshot(
            account: row.account,
            snapshot: row.snapshot,
            error: row.error,
            sourceLabel: row.sourceLabel,
            credits: self.credits,
            weeklyResetCandidate: row.weeklyResetCandidate)
        self.codexAccountUsageSnapshotStore?.store(self.codexAccountSnapshots)
    }

    private static func codexAccountSnapshot(
        _ row: CodexAccountUsageSnapshot,
        matchesPublishedCreditsAccountKey accountKey: String,
        refreshGuard: CodexAccountScopedRefreshGuard?) -> Bool
    {
        guard CodexIdentityResolver.normalizeEmail(row.account.email) == accountKey else { return false }
        guard let refreshGuard else { return true }
        guard row.account.selectionSource == refreshGuard.source else { return false }
        switch refreshGuard.identity {
        case let .providerAccount(id):
            return CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(row.account.workspaceAccountID)
                == CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(id)
        case .emailOnly, .unresolved:
            return true
        }
    }
}
