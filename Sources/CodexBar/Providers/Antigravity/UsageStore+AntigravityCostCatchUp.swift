import CodexBarCore
import Foundation

extension UsageStore {
    private static let antigravityMaxCatchUpPasses = 64

    func handleAntigravityCostCatchUp(
        afterRefreshing provider: UsageProvider,
        result: CostUsageTokenResult,
        scopeSignature: String)
    {
        guard provider == .antigravity else { return }
        guard !self.isClearingCostUsageCache,
              result.antigravityCatchUpPending,
              result.antigravityCatchUpMadeProgress
        else {
            self.cancelAntigravityCostCatchUp()
            return
        }
        guard self._test_tokenUsageSnapshotLoaderOverride == nil else {
            self.cancelAntigravityCostCatchUp()
            return
        }
        if self.antigravityCostCatchUpTask != nil,
           self.antigravityCostCatchUpRun?.scopeSignature == scopeSignature
        {
            return
        }
        self.startAntigravityCostCatchUp(scopeSignature: scopeSignature)
    }

    func cancelAntigravityCostCatchUpIfNeeded(for provider: UsageProvider) {
        guard provider == .antigravity else { return }
        self.cancelAntigravityCostCatchUp()
    }

    func cancelAntigravityCostCatchUp() {
        self.antigravityCostCatchUpTask?.cancel()
        self.antigravityCostCatchUpTask = nil
        self.antigravityCostCatchUpRun = nil
    }

    func drainAntigravityCostCatchUp() async {
        while !self.antigravityCostCatchUpTasksInFlight.isEmpty || self.antigravityCostCatchUpTask != nil {
            let tasks = Array(self.antigravityCostCatchUpTasksInFlight.values)
            self.cancelAntigravityCostCatchUp()
            for task in tasks {
                task.cancel()
                await task.value
            }
        }
    }

    func drainCostUsageWritersBeforeCacheClear() async {
        self.costUsageCacheClearGeneration &+= 1
        self.pendingForcedTokenRefresh = false
        self.tokenRefreshRetryProviders.removeAll()

        let antigravityID = UsageProvider.antigravity.instanceID
        while !self.antigravityCostCatchUpTasksInFlight.isEmpty
            || self.antigravityCostCatchUpTask != nil
            || self.tokenRefreshSequenceTask != nil
            || !self.scopedTokenRefreshTasks.isEmpty
            || self.spendDashboardTokenRefreshTasks[antigravityID] != nil
        {
            await self.drainAntigravityCostCatchUp()
            if let sequenceTask = self.tokenRefreshSequenceTask {
                self.tokenRefreshSequenceTask = nil
                sequenceTask.cancel()
                await sequenceTask.value
            }
            let scopedEntries = Array(self.scopedTokenRefreshTasks.values)
            self.scopedTokenRefreshTasks.removeAll()
            for entry in scopedEntries {
                entry.task.cancel()
                await entry.task.value
            }
            if let dashboardTask = self.spendDashboardTokenRefreshTasks.removeValue(forKey: antigravityID) {
                dashboardTask.cancel()
                _ = try? await dashboardTask.value
            }
        }

        while self.tokenRefreshInFlight.contains(antigravityID) {
            await withCheckedContinuation { continuation in
                self.tokenRefreshDrainWaiters[antigravityID, default: []].append(continuation)
            }
        }

        while self.spendDashboardTokenRefreshInFlight.contains(antigravityID) {
            await withCheckedContinuation { continuation in
                self.spendDashboardTokenRefreshDrainWaiters[antigravityID, default: []].append(continuation)
            }
        }
    }

    private func startAntigravityCostCatchUp(scopeSignature: String) {
        self.cancelAntigravityCostCatchUp()
        let token = UUID()
        self.antigravityCostCatchUpRun = (token, scopeSignature)
        let task = Task(priority: .background) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.antigravityCostCatchUpTasksInFlight.removeValue(forKey: token)
                if self.antigravityCostCatchUpRun?.token == token {
                    self.antigravityCostCatchUpTask = nil
                    self.antigravityCostCatchUpRun = nil
                }
            }
            await self.runAntigravityCostCatchUp(token: token, scopeSignature: scopeSignature)
        }
        self.antigravityCostCatchUpTask = task
        self.antigravityCostCatchUpTasksInFlight[token] = task
    }

    private func runAntigravityCostCatchUp(token: UUID, scopeSignature: String) async {
        let clearGeneration = self.costUsageCacheClearGeneration
        var previousActiveDuration: TimeInterval?
        var burstCompletedPasses = 0
        var completedScanPasses = 0

        while completedScanPasses < Self.antigravityMaxCatchUpPasses {
            guard !Task.isCancelled,
                  self.antigravityCostCatchUpRun?.token == token,
                  !self.isClearingCostUsageCache,
                  self.costUsageCacheClearGeneration == clearGeneration,
                  self.settings.isCostUsageEffectivelyEnabled(for: .antigravity),
                  self.isEnabled(.antigravity)
            else { return }

            let decision = self.codexCostCatchUpDecision(
                mode: .automatic,
                previousActiveDuration: previousActiveDuration,
                completedPasses: burstCompletedPasses,
                resourceState: self._test_antigravityCostCatchUpResourceStateOverride?())
            switch decision.action {
            case let .pause(delay, _):
                do {
                    try await self.sleepBetweenAntigravityCostCatchUpPasses(seconds: delay)
                } catch {
                    return
                }
                continue
            case let .runAfter(delay):
                if delay > 0 {
                    previousActiveDuration = nil
                    burstCompletedPasses = 0
                    do {
                        try await self.sleepBetweenAntigravityCostCatchUpPasses(seconds: delay)
                    } catch {
                        return
                    }
                } else if completedScanPasses > 0 {
                    do {
                        try await self.sleepBetweenAntigravityCostCatchUpPasses(seconds: 0)
                    } catch {
                        return
                    }
                }
            }

            guard !Task.isCancelled,
                  self.antigravityCostCatchUpRun?.token == token,
                  !self.isClearingCostUsageCache,
                  self.costUsageCacheClearGeneration == clearGeneration,
                  self.settings.isCostUsageEffectivelyEnabled(for: .antigravity),
                  self.isEnabled(.antigravity)
            else { return }

            let now = Date()
            let historyDays = self.settings.costReportingPeriod.days(
                now: now,
                calendar: self.settings.costUsageBucketCalendar)
            let currentScope = self.tokenSnapshotScopeSignature(for: .antigravity)
            guard currentScope == scopeSignature else { return }

            let passStarted = Date()
            let result: CostUsageTokenResult
            do {
                result = try await self.loadTokenUsageSnapshot(
                    provider: .antigravity,
                    force: false,
                    now: now,
                    codexHomePath: nil,
                    historyDays: historyDays,
                    includePiSessions: false)
            } catch {
                return
            }
            let elapsed = max(0, result.antigravityScanActiveDuration ?? Date().timeIntervalSince(passStarted))
            previousActiveDuration = (previousActiveDuration ?? 0) + elapsed
            burstCompletedPasses += 1
            completedScanPasses += 1

            guard !Task.isCancelled,
                  self.antigravityCostCatchUpRun?.token == token,
                  !self.isClearingCostUsageCache,
                  self.costUsageCacheClearGeneration == clearGeneration,
                  self.tokenSnapshotScopeSignature(for: .antigravity) == currentScope
            else { return }

            self.publishAntigravityCatchUpResult(result, scopeSignature: currentScope, now: now)

            guard result.antigravityCatchUpPending, result.antigravityCatchUpMadeProgress else { return }
        }
    }

    private func sleepBetweenAntigravityCostCatchUpPasses(seconds: TimeInterval) async throws {
        if let override = self._test_antigravityCostCatchUpSleepOverride {
            try await override(max(0, seconds))
            return
        }
        guard seconds > 0 else {
            await Task.yield()
            return
        }
        try await Task.sleep(for: .seconds(seconds))
    }

    private func publishAntigravityCatchUpResult(
        _ result: CostUsageTokenResult,
        scopeSignature: String,
        now: Date)
    {
        let confirmedEmpty = (try? self.regularTokenSnapshotIsConfirmedEmpty(
            result.snapshot,
            for: .antigravity)) == true
        guard confirmedEmpty || !result.snapshot.daily.isEmpty || result.snapshot.historyCoverageIsEstablished
        else { return }

        if confirmedEmpty {
            self.publishConfirmedEmptyTokenSnapshot(for: .antigravity, accounting: result.accounting)
            self.tokenErrors[UsageProvider.antigravity.instanceID] = Self.tokenCostNoDataMessage(for: .antigravity)
        } else {
            self.publishTokenSnapshot(result.snapshot, for: .antigravity, accounting: result.accounting)
            self.tokenErrors[UsageProvider.antigravity.instanceID] = nil
        }
        self.lastTokenFetchScope[UsageProvider.antigravity.instanceID] = scopeSignature
        if !result.antigravityCatchUpPending {
            self.lastTokenFetchAt[UsageProvider.antigravity.instanceID] = now
        }
        self.tokenFailureGates[UsageProvider.antigravity.instanceID]?.recordSuccess()
        self.persistWidgetSnapshot(reason: "antigravity-catchup")
    }
}
