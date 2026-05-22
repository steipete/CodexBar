import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    nonisolated static let codexSnapshotWaitTimeoutSeconds: TimeInterval = 6
    nonisolated static let codexRefreshStartGraceSeconds: TimeInterval = 0.25
    nonisolated static let codexSnapshotPollIntervalNanoseconds: UInt64 = 100_000_000

    func codexCreditsFetcher() -> UsageFetcher {
        // Credits are remote Codex account state, so they need the same managed-home routing as the
        // primary Codex usage fetch. Local token-cost scanning intentionally stays ambient-system scoped.
        self.makeFetchContext(provider: .codex, override: nil).fetcher
    }

    func scheduleCreditsRefreshIfNeeded(minimumSnapshotUpdatedAt: Date? = nil) {
        let refreshKey = self.codexCreditsRefreshKey(
            expectedGuard: self.currentCodexAccountScopedRefreshGuard())
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
            self.persistWidgetSnapshot(reason: "credits")
        }
    }

    func codexCreditsRefreshKey(expectedGuard: CodexAccountScopedRefreshGuard) -> String {
        let sourceKey = switch expectedGuard.source {
        case .liveSystem:
            "live"
        case let .managedAccount(id):
            "managed:\(id.uuidString)"
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
        ].joined(separator: "|")
    }

    func refreshCreditsIfNeeded(minimumSnapshotUpdatedAt: Date? = nil) async {
        guard self.isEnabled(.codex) else { return }
        var expectedGuard = self.currentCodexAccountScopedRefreshGuard()
        if expectedGuard.identity == .unresolved,
           let minimumSnapshotUpdatedAt,
           case .liveSystem = expectedGuard.source
        {
            _ = await self.waitForCodexSnapshotOrRefreshCompletion(minimumUpdatedAt: minimumSnapshotUpdatedAt)
            expectedGuard = self.currentCodexAccountScopedRefreshGuard()
        }
        guard expectedGuard.identity != .unresolved,
              expectedGuard.accountKey != nil
        else {
            return
        }
        do {
            let credits = try await self.loadLatestCodexCredits()
            guard self.shouldApplyCodexScopedNonUsageResult(expectedGuard: expectedGuard) else { return }
            await MainActor.run {
                self.credits = credits
                self.lastCreditsError = nil
                self.lastCreditsSnapshot = credits
                self.lastCreditsSnapshotAccountKey = expectedGuard.accountKey
                self.lastCreditsSource = .api
                self.creditsFailureStreak = 0
                self.lastCodexAccountScopedRefreshGuard = expectedGuard
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
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("data not available yet") {
                guard self.shouldApplyCodexScopedNonUsageResult(expectedGuard: expectedGuard) else { return }
                await MainActor.run {
                    if let cached = self.lastCreditsSnapshot,
                       self.lastCreditsSnapshotAccountKey == expectedGuard.accountKey
                    {
                        self.credits = cached
                        self.lastCreditsError = nil
                        self.lastCodexAccountScopedRefreshGuard = expectedGuard
                    } else {
                        self.credits = nil
                        self.lastCreditsSource = .none
                        self.lastCreditsError = "Codex credits are still loading; will retry shortly."
                    }
                }
                return
            }

            guard self.shouldApplyCodexScopedNonUsageResult(expectedGuard: expectedGuard) else { return }
            await MainActor.run {
                self.creditsFailureStreak += 1
                if let cached = self.lastCreditsSnapshot,
                   self.lastCreditsSnapshotAccountKey == expectedGuard.accountKey
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

    private func loadLatestCodexCredits() async throws -> CreditsSnapshot {
        if let override = self._test_codexCreditsLoaderOverride {
            return try await override()
        }
        let descriptor = self.providerSpecs[.codex]?.descriptor ?? ProviderDescriptorRegistry.descriptor(for: .codex)
        let context = self.makeFetchContext(provider: .codex, override: nil, includeCredits: true)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        var lastAvailableError: Error?

        for strategy in strategies {
            guard await strategy.isAvailable(context) else { continue }
            do {
                let result = try await strategy.fetch(context)
                if let credits = result.credits {
                    return credits
                }
                lastAvailableError = UsageError.noRateLimitsFound
                guard context.sourceMode == .auto else { break }
            } catch {
                lastAvailableError = error
                guard strategy.shouldFallback(on: error, context: context) else { break }
            }
        }
        throw lastAvailableError ?? ProviderFetchError.noAvailableStrategy(.codex)
    }

    func waitForCodexSnapshot(minimumUpdatedAt: Date) async -> UsageSnapshot? {
        let deadline = Date().addingTimeInterval(Self.codexSnapshotWaitTimeoutSeconds)

        while Date() < deadline {
            if Task.isCancelled { return nil }
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
            if Task.isCancelled { return nil }
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
}
