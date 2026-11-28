import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    struct DeepSeekHistoryOwnerKey: Equatable, Sendable {
        let cleanupRevision: UInt64
        let enablementRevision: UInt64
        let configRevision: UInt64
        let selectedTokenAccountID: UUID?
        let profileID: String?
        let ownerTokenDigest: String?
        let sourceLabel: String
    }

    struct DeepSeekHistoryRequestScope: Equatable, Sendable {
        let owner: DeepSeekHistoryOwnerKey
        let period: CostReportingPeriod
        let costUsageSettingsRevision: UInt64
        let bucketTimeZoneIdentifier: String
        let timeZoneSeconds: Int
        let anchorDayKey: String
    }

    struct DeepSeekProjectedHistory: Equatable, Sendable {
        let costUsage: CostUsageTokenSnapshot
        let details: [ProviderDetailSection]
        let failedChunkCount: Int

        fileprivate func attaching(to snapshot: UsageSnapshot) -> UsageSnapshot {
            snapshot.withDeepSeekProjectedUsage(costUsage: self.costUsage, details: self.details)
        }
    }

    struct DeepSeekHistoryRuntimeState: Sendable {
        var owner: DeepSeekHistoryOwnerKey
        var activeScope: DeepSeekHistoryRequestScope?
        var activeProjection: DeepSeekProjectedHistory?
        var activePlan: DeepSeekHistoryPlan?
        var completedScope: DeepSeekHistoryRequestScope?
        var completedProjection: DeepSeekProjectedHistory?
        var completedProjectionRevision: UInt64?
        var completedPlan: DeepSeekHistoryPlan?
        var completedFailedChunkCount: Int = 0
        var headRevision: UInt64 = 0
        var needsHeadProjection: Bool = false
        /// Verified UTC offset and bucket timezone identifier for every entry currently in `chunksByWindow`.
        var chunksTimeZoneSeconds: Int?
        var chunksBucketTimeZoneIdentifier: String?
        /// Compact folded chunks keyed by exact `[start, end)` window for same-owner reuse and head replacement.
        var chunksByWindow: [DeepSeekUsageWindow: DeepSeekChunkFoldResult] = [:]

        fileprivate mutating func resetChunksIfTimeZoneChanged(for scope: DeepSeekHistoryRequestScope) {
            guard self.chunksBucketTimeZoneIdentifier != scope.bucketTimeZoneIdentifier
                || self.chunksTimeZoneSeconds != scope.timeZoneSeconds
            else { return }
            self.chunksByWindow.removeAll()
            self.chunksBucketTimeZoneIdentifier = scope.bucketTimeZoneIdentifier
            self.chunksTimeZoneSeconds = scope.timeZoneSeconds
        }

        fileprivate mutating func replaceRecentFold(
            _ recentFold: DeepSeekChunkFoldResult,
            in plan: DeepSeekHistoryPlan)
        {
            let plannedWindows = Set(plan.chunks)
            self.chunksByWindow = self.chunksByWindow.filter { plannedWindows.contains($0.key) }
            self.chunksByWindow[recentFold.window] = recentFold
        }

        fileprivate mutating func clearActive() {
            self.activeScope = nil
            self.activeProjection = nil
            self.activePlan = nil
        }

        fileprivate mutating func clearCompleted() {
            self.completedScope = nil
            self.completedProjection = nil
            self.completedProjectionRevision = nil
            self.completedPlan = nil
            self.completedFailedChunkCount = 0
        }
    }

    private func cancelDeepSeekHistoryTasks() {
        self.deepseekHistoryGeneration &+= 1
        self.deepseekHistoryTask?.cancel()
        self.deepseekHistoryTask = nil
        self.deepseekHeadProjectionTask?.cancel()
        self.deepseekHeadProjectionTask = nil
    }

    func cancelDeepSeekWideHistory() {
        self.cancelDeepSeekHistoryTasks()
        self.deepseekHistoryState = nil
    }

    func cancelDeepSeekWideHistoryIfNeeded(for provider: UsageProvider) {
        guard provider == .deepseek else { return }
        self.cancelDeepSeekWideHistory()
    }

    func reconcileDeepSeekHistoryScopeIfInvalid(for provider: UsageProvider) {
        guard provider == .deepseek else { return }
        self.reconcileDeepSeekHistoryScopeIfInvalid()
    }

    func prepareDeepSeekSelectedAccountSnapshot(
        _ snapshot: UsageSnapshot,
        result: ProviderFetchResult,
        account: ProviderTokenAccount?) -> UsageSnapshot
    {
        let prepared = snapshot
            .preservingDeepSeekPlatformProfiles(from: self.presentationSnapshot(for: .deepseek))
            .backfillingResetTimes(from: self.lastKnownResetSnapshots[.deepseek])
        return self.reconcileDeepSeekRefreshPublication(snapshot: prepared, result: result, account: account)
    }

    func finalizeDeepSeekSelectedAccountPublication(
        snapshot: UsageSnapshot,
        result: ProviderFetchResult,
        account: ProviderTokenAccount?)
    {
        self.clearDeepSeekProfileTransition()
        self.publishProviderDerivedTokenSnapshot(from: snapshot, for: .deepseek)
        if let account,
           let currentAccount = self.uniqueTokenAccount(provider: .deepseek, accountID: account.id)
        {
            self.cacheTokenAccountSnapshot(
                provider: .deepseek,
                account: currentAccount,
                snapshot: snapshot,
                sourceLabel: result.sourceLabel)
        }
        let explicit = ProviderInteractionContext.current == .userInitiated
        self.scheduleDeepSeekWideHistoryIfNeeded(result: result, account: account, isExplicitReload: explicit)
    }

    func reconcileDeepSeekHistoryScopeIfInvalid() {
        guard var state = self.deepseekHistoryState else { return }
        let now = self.deepseekHistoryNow()
        let currentOffset = self.currentDeepSeekBucketTimeZoneOffset(at: now)
        let currentZoneID = self.settings.costUsageBucketTimeZoneIdentifier
        guard self.isDeepSeekHistoryOwnerCurrent(state.owner),
              self.settings.showOptionalCreditsAndExtraUsage,
              self.settings.isCostUsageEffectivelyEnabled(for: .deepseek),
              state.chunksBucketTimeZoneIdentifier == nil || state.chunksBucketTimeZoneIdentifier == currentZoneID,
              state.chunksTimeZoneSeconds == nil || state.chunksTimeZoneSeconds == currentOffset
        else {
            self.cancelDeepSeekWideHistory()
            return
        }

        // Active is checked first; the first stale scope decides between reuse and a full reset.
        let staleScope = [state.activeScope, state.completedScope].compactMap(\.self)
            .first { !self.isDeepSeekHistoryScopeCurrentIgnoringGeneration($0) }
        guard let staleScope else { return }
        if self.isDeepSeekScopeEligibleForMidnightRolloverReuse(
            staleScope,
            currentZoneID: currentZoneID,
            currentOffset: currentOffset)
        {
            self.retireDeepSeekScopesPreservingReusableChunks(&state)
        } else {
            self.cancelDeepSeekWideHistory()
        }
    }

    /// Reconciles a freshly fetched DeepSeek snapshot (balance + recent chunk) against any active
    /// or completed wide-history state for the same owner without cancelling in-flight wide work.
    func reconcileDeepSeekRefreshPublication(
        snapshot: UsageSnapshot,
        result: ProviderFetchResult,
        account: ProviderTokenAccount?) -> UsageSnapshot
    {
        guard self.settings.showOptionalCreditsAndExtraUsage,
              self.settings.isCostUsageEffectivelyEnabled(for: .deepseek)
        else {
            self.cancelDeepSeekWideHistory()
            return snapshot
        }

        guard let continuation = result.deepseekHistoryContinuation else {
            return self.reconcileDeepSeekRefreshWithoutContinuation(
                snapshot: snapshot,
                result: result,
                account: account)
        }

        let metadata = continuation.metadata
        let plan = metadata.plan
        let scope = self.makeDeepSeekHistoryRequestScope(
            metadata: metadata,
            sourceLabel: result.sourceLabel,
            account: account)

        if self.deepseekProfileTransition != nil || self.deepseekHistoryState?.owner != scope.owner {
            self.cancelDeepSeekWideHistory()
            self.deepseekHistoryState = DeepSeekHistoryRuntimeState(owner: scope.owner)
        }

        guard var state = self.deepseekHistoryState else { return snapshot }

        // Period, day, or offset change retires incompatible workers before adapting reusable chunks.
        if let activeScope = state.activeScope, activeScope != scope {
            self.cancelDeepSeekHistoryTasks()
            state.clearActive()
            state.needsHeadProjection = false
        }

        state.resetChunksIfTimeZoneChanged(for: scope)

        if !plan.isWide {
            // Short windows (1...30 days) already carry exact off-main projections on the snapshot.
            if self.deepseekHistoryTask != nil || self.deepseekHeadProjectionTask != nil {
                self.cancelDeepSeekHistoryTasks()
            }
            var shortState = DeepSeekHistoryRuntimeState(owner: scope.owner)
            shortState.completedScope = scope
            shortState.completedProjection = Self.existingDeepSeekProjection(from: snapshot, failedChunkCount: 0)
            shortState.chunksBucketTimeZoneIdentifier = scope.bucketTimeZoneIdentifier
            shortState.chunksTimeZoneSeconds = scope.timeZoneSeconds
            shortState.chunksByWindow = [metadata.recentFold.window: metadata.recentFold]
            self.deepseekHistoryState = shortState
            return snapshot
        }

        let headWindow = metadata.recentFold.window
        let headChanged = state.chunksByWindow[headWindow] != metadata.recentFold

        if state.completedScope == scope {
            return self.reconcileCompletedDeepSeekWideRefresh(
                snapshot: snapshot,
                plan: plan,
                recentFold: metadata.recentFold,
                headChanged: headChanged,
                state: &state)
        }

        // Any scope change (midnight rollover, period, settings, or timezone offset) retires the prior
        // completed projection and adapts valid same-offset reusable chunks so fresh recent data publishes
        // immediately with honest partial coverage while one coalesced wide backfill fills boundary gaps.
        return self.reconcileActiveOrRolledDeepSeekWideRefresh(
            snapshot: snapshot,
            scope: scope,
            metadata: metadata,
            headChanged: headChanged,
            state: &state)
    }

    private func reconcileActiveOrRolledDeepSeekWideRefresh(
        snapshot: UsageSnapshot,
        scope: DeepSeekHistoryRequestScope,
        metadata: DeepSeekHistorySessionMetadata,
        headChanged: Bool,
        state: inout DeepSeekHistoryRuntimeState) -> UsageSnapshot
    {
        let plan = metadata.plan
        let recentFold = metadata.recentFold
        if self.deepseekHeadProjectionTask != nil {
            self.deepseekHeadProjectionTask?.cancel()
            self.deepseekHeadProjectionTask = nil
            state.headRevision &+= 1
        }
        let isSameActiveScopeTick = state.activeScope == scope && !headChanged
        let effectivePlan: DeepSeekHistoryPlan
        if state.activeScope == scope,
           let activePlan = state.activePlan,
           Self.isDeepSeekPlanCompatible(activePlan, with: plan)
        {
            effectivePlan = isSameActiveScopeTick ? activePlan : activePlan.withAnchorDate(plan.anchorDate)
        } else {
            let reusableKeys = self.reusableDeepSeekWindowKeys(in: state, for: scope)
            effectivePlan = plan.adaptingToReusableWindows(reusableKeys)
        }
        state.replaceRecentFold(recentFold, in: effectivePlan)
        state.activePlan = effectivePlan
        state.clearCompleted()
        state.needsHeadProjection = false
        if !isSameActiveScopeTick || state.activeProjection == nil {
            state.activeProjection = Self.existingDeepSeekProjection(
                from: snapshot,
                failedChunkCount: max(0, effectivePlan.chunks.count - 1))
        }
        self.deepseekHistoryState = state
        return snapshot
    }

    private func reconcileCompletedDeepSeekWideRefresh(
        snapshot: UsageSnapshot,
        plan: DeepSeekHistoryPlan,
        recentFold: DeepSeekChunkFoldResult,
        headChanged: Bool,
        state: inout DeepSeekHistoryRuntimeState) -> UsageSnapshot
    {
        if !headChanged, state.completedProjection != nil, state.completedProjectionRevision == state.headRevision {
            state.needsHeadProjection = false
        } else if headChanged || self.deepseekHeadProjectionTask == nil {
            // Replace matching head contribution in place and defer full-range merge/projection off MainActor.
            let effectivePlan = (state.completedPlan.flatMap {
                Self.isDeepSeekPlanCompatible($0, with: plan) ? $0 : nil
            } ?? plan).withAnchorDate(plan.anchorDate)
            state.replaceRecentFold(recentFold, in: effectivePlan)
            state.headRevision &+= 1
            state.completedPlan = effectivePlan
            state.needsHeadProjection = true
        }
        self.deepseekHistoryState = state
        return state.completedProjection?.attaching(to: snapshot) ?? snapshot
    }

    private func reconcileDeepSeekRefreshWithoutContinuation(
        snapshot: UsageSnapshot,
        result: ProviderFetchResult,
        account: ProviderTokenAccount?) -> UsageSnapshot
    {
        guard case let .transientOptionalDetailUnavailable(transientScope) = result.deepseekHistoryRefreshDisposition,
              var state = self.deepseekHistoryState,
              self.matchesDeepSeekTransientScope(
                  transientScope,
                  owner: state.owner,
                  sourceLabel: result.sourceLabel,
                  account: account)
        else {
            self.cancelDeepSeekWideHistory()
            return snapshot
        }

        let hasCurrentActiveWorker: Bool
        if let activeScope = state.activeScope, self.deepseekHistoryTask != nil {
            if activeScope.period == transientScope.period,
               activeScope.bucketTimeZoneIdentifier == transientScope.bucketTimeZoneIdentifier,
               self.isDeepSeekHistoryScopeCurrentIgnoringGeneration(activeScope)
            {
                hasCurrentActiveWorker = true
            } else {
                self.deepseekHistoryGeneration &+= 1
                self.deepseekHistoryTask?.cancel()
                self.deepseekHistoryTask = nil
                state.clearActive()
                hasCurrentActiveWorker = false
            }
        } else {
            state.clearActive()
            hasCurrentActiveWorker = false
        }

        let completedScopeCompatible: Bool = if let completedScope = state.completedScope {
            self.isDeepSeekCompletedScopeCompatible(
                completedScope,
                with: transientScope,
                owner: state.owner)
        } else {
            false
        }

        let hasCurrentHeadProjection = completedScopeCompatible && self.deepseekHeadProjectionTask != nil
        let preservedCompletedProjection: DeepSeekProjectedHistory?
        if completedScopeCompatible, let completedProjection = state.completedProjection {
            preservedCompletedProjection = completedProjection
        } else if hasCurrentHeadProjection {
            preservedCompletedProjection = self.snapshots[.deepseek].flatMap {
                Self.existingDeepSeekProjection(from: $0, failedChunkCount: state.completedFailedChunkCount)
            }
        } else {
            preservedCompletedProjection = nil
            self.deepseekHeadProjectionTask?.cancel()
            self.deepseekHeadProjectionTask = nil
            state.needsHeadProjection = false
            if !hasCurrentActiveWorker {
                self.cancelDeepSeekWideHistory()
                return snapshot
            }
            state.clearCompleted()
        }

        self.deepseekHistoryState = state
        return (preservedCompletedProjection ?? state.activeProjection)?.attaching(to: snapshot) ?? snapshot
    }

    func scheduleDeepSeekWideHistoryIfNeeded(
        result: ProviderFetchResult,
        account: ProviderTokenAccount?,
        isExplicitReload: Bool)
    {
        guard let continuation = result.deepseekHistoryContinuation else { return }
        let metadata = continuation.metadata
        let plan = metadata.plan
        guard plan.isWide else { return }

        let scope = self.makeDeepSeekHistoryRequestScope(
            metadata: metadata,
            sourceLabel: result.sourceLabel,
            account: account)
        guard self.isDeepSeekHistoryScopeCurrentIgnoringGeneration(scope) else { return }

        if var state = self.deepseekHistoryState {
            // Identical in-flight work coalesces; routine ticks must not cancel or duplicate it.
            if state.activeScope == scope, self.deepseekHistoryTask != nil {
                return
            }
            // Completed (including terminal partial) scope does not requeue older fetches on routine ticks;
            // explicit user reloads retry missing pages, and changed heads project off MainActor.
            if state.completedScope == scope {
                let shouldRetryMissingPages = isExplicitReload && state.completedFailedChunkCount > 0
                if !shouldRetryMissingPages {
                    if state.needsHeadProjection {
                        state.needsHeadProjection = false
                        let headPlan = state.completedPlan ?? plan
                        let orderedFolds = headPlan.chunks.compactMap { state.chunksByWindow[$0] }
                        let failedChunkCount = state.completedFailedChunkCount
                        let headRevision = state.headRevision
                        self.deepseekHistoryState = state
                        self.scheduleDeepSeekHeadProjection(DeepSeekHeadProjectionRequest(
                            scope: scope,
                            plan: headPlan,
                            orderedFolds: orderedFolds,
                            failedChunkCount: failedChunkCount,
                            generation: self.deepseekHistoryGeneration,
                            headRevision: headRevision,
                            account: account))
                    }
                    return
                }
            }
        }

        self.deepseekHistoryGeneration &+= 1
        let generation = self.deepseekHistoryGeneration
        self.deepseekHistoryTask?.cancel()
        self.deepseekHeadProjectionTask?.cancel()
        self.deepseekHeadProjectionTask = nil

        var state = self.deepseekHistoryState?.owner == scope.owner
            ? self.deepseekHistoryState!
            : DeepSeekHistoryRuntimeState(owner: scope.owner)
        state.resetChunksIfTimeZoneChanged(for: scope)
        let effectivePlan = self.resolvedEffectiveDeepSeekPlan(
            incomingPlan: plan,
            scope: scope,
            state: state)
        state.replaceRecentFold(metadata.recentFold, in: effectivePlan)
        state.activeScope = scope
        state.activePlan = effectivePlan
        state.needsHeadProjection = false
        let reusableChunks = state.chunksByWindow
        self.deepseekHistoryState = state

        let workerInput = DeepSeekWideWorkerInput(
            plan: effectivePlan,
            recentFold: metadata.recentFold,
            reusableChunks: reusableChunks,
            fetchChunk: continuation.fetchChunk,
            projectionObserver: self.deepseekProjectionObserverForTesting)
        let task = Task(priority: .utility) { @MainActor [weak self] in
            defer {
                self?.finishDeepSeekWideHistorySlotIfCurrent(generation: generation)
            }
            guard self != nil else { return }
            let fetchResult = await Self.runDeepSeekWideHistoryWorker(
                workerInput,
                isStillValid: { [weak self] in
                    await MainActor.run {
                        guard let self else { return false }
                        let isCurrent = self.isDeepSeekHistoryScopeCurrent(scope, generation: generation)
                        if !isCurrent {
                            self.finishDeepSeekWideHistorySlotIfCurrent(generation: generation)
                        }
                        return isCurrent
                    }
                })
            guard let self,
                  !Task.isCancelled,
                  self.isDeepSeekHistoryScopeCurrent(scope, generation: generation),
                  let fetchResult
            else {
                return
            }
            self.publishCompletedDeepSeekWideHistory(DeepSeekWidePublication(
                generation: generation,
                scope: scope,
                plan: effectivePlan,
                output: fetchResult,
                recentFallbackFold: metadata.recentFold,
                account: account))
        }
        self.deepseekHistoryTask = task
    }

    private func scheduleDeepSeekHeadProjection(_ request: DeepSeekHeadProjectionRequest) {
        self.deepseekHeadProjectionTask?.cancel()
        let projectionInput = DeepSeekProjectionInput(
            plan: request.plan,
            orderedFolds: request.orderedFolds,
            failedChunkCount: request.failedChunkCount,
            projectionObserver: self.deepseekProjectionObserverForTesting)
        let task = Task(priority: .utility) { @MainActor [weak self] in
            defer {
                self?.finishDeepSeekHeadProjectionSlotIfCurrent(
                    generation: request.generation,
                    headRevision: request.headRevision)
            }
            guard self != nil else { return }
            let projection = await Self.buildDeepSeekProjectedHistory(projectionInput)
            guard let self,
                  !Task.isCancelled,
                  let projection,
                  self.isDeepSeekHistoryScopeCurrent(request.scope, generation: request.generation),
                  var state = self.deepseekHistoryState,
                  state.completedScope == request.scope,
                  state.headRevision == request.headRevision,
                  let liveSnapshot = self.snapshots[.deepseek]
            else {
                return
            }
            state.completedProjection = projection
            state.completedProjectionRevision = request.headRevision
            state.completedPlan = request.plan
            state.completedFailedChunkCount = projection.failedChunkCount
            self.deepseekHistoryState = state
            self.deepseekHeadProjectionTask = nil
            self.applyDeepSeekProjectedHistory(
                projection,
                to: liveSnapshot,
                account: request.account,
                sourceLabel: request.scope.owner.sourceLabel)
        }
        self.deepseekHeadProjectionTask = task
    }

    private func finishDeepSeekWideHistorySlotIfCurrent(generation: UInt64) {
        guard self.deepseekHistoryGeneration == generation else { return }
        self.deepseekHistoryTask = nil
        self.deepseekHistoryState?.clearActive()
    }

    private func finishDeepSeekHeadProjectionSlotIfCurrent(generation: UInt64, headRevision: UInt64) {
        guard self.deepseekHistoryGeneration == generation,
              self.deepseekHistoryState?.headRevision == headRevision
        else { return }
        self.deepseekHeadProjectionTask = nil
    }

    private struct DeepSeekProjectionInput: Sendable {
        let plan: DeepSeekHistoryPlan
        let orderedFolds: [DeepSeekChunkFoldResult]
        let failedChunkCount: Int
        let projectionObserver: (@Sendable (_ isMainThread: Bool) async -> Void)?
    }

    private struct DeepSeekWideWorkerInput: Sendable {
        let plan: DeepSeekHistoryPlan
        let recentFold: DeepSeekChunkFoldResult
        let reusableChunks: [DeepSeekUsageWindow: DeepSeekChunkFoldResult]
        let fetchChunk: @Sendable (DeepSeekUsageWindow) async throws -> DeepSeekChunkFoldResult
        let projectionObserver: (@Sendable (_ isMainThread: Bool) async -> Void)?
    }

    private struct DeepSeekWideWorkerOutput: Sendable {
        let olderFolds: [DeepSeekUsageWindow: DeepSeekChunkFoldResult]
        let rawFailedChunkCount: Int
        let projection: DeepSeekProjectedHistory
    }

    private struct DeepSeekWidePublication {
        let generation: UInt64
        let scope: DeepSeekHistoryRequestScope
        let plan: DeepSeekHistoryPlan
        let output: DeepSeekWideWorkerOutput
        let recentFallbackFold: DeepSeekChunkFoldResult
        let account: ProviderTokenAccount?
    }

    private struct DeepSeekHeadProjectionRequest {
        let scope: DeepSeekHistoryRequestScope
        let plan: DeepSeekHistoryPlan
        let orderedFolds: [DeepSeekChunkFoldResult]
        let failedChunkCount: Int
        let generation: UInt64
        let headRevision: UInt64
        let account: ProviderTokenAccount?
    }

    private var deepseekProjectionObserverForTesting: (@Sendable (_ isMainThread: Bool) async -> Void)? {
        #if DEBUG
        self._test_deepseekProjectionObserver
        #else
        nil
        #endif
    }

    private static func existingDeepSeekProjection(
        from snapshot: UsageSnapshot,
        failedChunkCount: Int) -> DeepSeekProjectedHistory?
    {
        guard let costUsage = snapshot.costUsage else { return nil }
        return DeepSeekProjectedHistory(
            costUsage: costUsage,
            details: snapshot.details,
            failedChunkCount: failedChunkCount)
    }

    private nonisolated static func isExecutingOnMainThread() -> Bool {
        Thread.isMainThread
    }

    /// Merges folded chunks and builds both `CostUsageTokenSnapshot` and detail sections strictly off MainActor.
    private nonisolated static func buildDeepSeekProjectedHistory(
        _ input: DeepSeekProjectionInput) async -> DeepSeekProjectedHistory?
    {
        if Task.isCancelled { return nil }
        if let observer = input.projectionObserver {
            await observer(self.isExecutingOnMainThread())
        }
        if Task.isCancelled { return nil }
        let summary = DeepSeekUsageCostParser.mergeByAPIKeyChunks(
            input.orderedFolds,
            plan: input.plan,
            failedChunkCount: input.failedChunkCount)
        let costUsage = summary.toCostUsageTokenSnapshot()
        let details = DeepSeekUsageSnapshot.detailSections(for: summary, referenceDate: input.plan.anchorDate)
        return DeepSeekProjectedHistory(
            costUsage: costUsage,
            details: details,
            failedChunkCount: summary.coverage?.failedChunkCount ?? input.failedChunkCount)
    }

    /// Runs off the main actor so each chunk's network pair, JSON decode, fold, merge, and projection
    /// execute on the cooperative pool and release raw payloads before the next page begins.
    private nonisolated static func runDeepSeekWideHistoryWorker(
        _ input: DeepSeekWideWorkerInput,
        isStillValid: @escaping @Sendable () async -> Bool) async -> DeepSeekWideWorkerOutput?
    {
        let olderWindows = Array(input.plan.chunks.dropFirst())
        guard case let .completed(olderFolds, failedChunkCount) = await DeepSeekUsageFetcher.paginateOlderChunks(
            olderWindows: olderWindows,
            reusableChunks: input.reusableChunks,
            fetchChunk: input.fetchChunk,
            isStillValid: isStillValid),
            !Task.isCancelled
        else {
            return nil
        }

        let orderedFolds = [input.recentFold] + olderWindows.compactMap { olderFolds[$0] }
        guard let projection = await Self.buildDeepSeekProjectedHistory(DeepSeekProjectionInput(
            plan: input.plan,
            orderedFolds: orderedFolds,
            failedChunkCount: failedChunkCount,
            projectionObserver: input.projectionObserver))
        else {
            return nil
        }
        return DeepSeekWideWorkerOutput(
            olderFolds: olderFolds,
            rawFailedChunkCount: failedChunkCount,
            projection: projection)
    }

    private func publishCompletedDeepSeekWideHistory(_ publication: DeepSeekWidePublication) {
        let scope = publication.scope
        let plan = publication.plan
        let output = publication.output
        guard self.deepseekHistoryGeneration == publication.generation,
              var state = self.deepseekHistoryState,
              state.owner == scope.owner,
              let liveSnapshot = self.snapshots[.deepseek]
        else { return }

        // Keep the freshest head chunk if a routine balance tick refreshed it while older pages loaded.
        let headWindow = plan.recentChunk
        let latestHead = state.chunksByWindow[headWindow] ?? publication.recentFallbackFold
        var finalChunks: [DeepSeekUsageWindow: DeepSeekChunkFoldResult] = [headWindow: latestHead]
        for (window, fold) in output.olderFolds {
            finalChunks[window] = fold
        }

        let latestHeadAnchorDate = state.activePlan?.anchorDate
        state.clearActive()
        state.completedScope = scope
        state.completedFailedChunkCount = output.projection.failedChunkCount
        state.chunksByWindow = finalChunks
        state.chunksBucketTimeZoneIdentifier = scope.bucketTimeZoneIdentifier
        state.chunksTimeZoneSeconds = scope.timeZoneSeconds
        state.needsHeadProjection = false
        self.deepseekHistoryTask = nil

        if latestHead == publication.recentFallbackFold {
            state.completedPlan = plan
            state.completedProjection = output.projection
            state.completedProjectionRevision = state.headRevision
            self.deepseekHistoryState = state
            self.applyDeepSeekProjectedHistory(
                output.projection,
                to: liveSnapshot,
                account: publication.account,
                sourceLabel: publication.scope.owner.sourceLabel)
            return
        }

        // A newer head arrived while older pages were loading: project the merged chunks strictly off MainActor.
        let headPlan = plan.withAnchorDate(latestHeadAnchorDate ?? plan.anchorDate)
        state.completedPlan = headPlan
        state.completedProjection = nil
        state.completedProjectionRevision = nil
        state.headRevision &+= 1
        let headRevision = state.headRevision
        self.deepseekHistoryState = state
        self.scheduleDeepSeekHeadProjection(DeepSeekHeadProjectionRequest(
            scope: scope,
            plan: headPlan,
            orderedFolds: headPlan.chunks.compactMap { finalChunks[$0] },
            failedChunkCount: output.rawFailedChunkCount,
            generation: publication.generation,
            headRevision: headRevision,
            account: publication.account))
    }

    private func applyDeepSeekProjectedHistory(
        _ projection: DeepSeekProjectedHistory,
        to liveSnapshot: UsageSnapshot,
        account: ProviderTokenAccount?,
        sourceLabel: String)
    {
        // Attach prebuilt history onto the latest live balance snapshot without overwriting balance freshness.
        let updatedSnapshot = projection.attaching(to: liveSnapshot)
        let snapshotChanged = liveSnapshot.costUsage != updatedSnapshot.costUsage
            || liveSnapshot.details != updatedSnapshot.details
        self.snapshots[.deepseek] = updatedSnapshot
        self.lastKnownResetSnapshots[.deepseek] = updatedSnapshot
        if let account,
           let currentAccount = self.uniqueTokenAccount(provider: .deepseek, accountID: account.id)
        {
            self.cacheTokenAccountSnapshot(
                provider: .deepseek,
                account: currentAccount,
                snapshot: updatedSnapshot,
                sourceLabel: sourceLabel)
        }
        if snapshotChanged {
            self.publishProviderDerivedTokenSnapshot(from: updatedSnapshot, for: .deepseek)
            self.persistWidgetSnapshot(reason: "deepseek-history")
        }
    }

    private func makeDeepSeekHistoryRequestScope(
        metadata: DeepSeekHistorySessionMetadata,
        sourceLabel: String,
        account: ProviderTokenAccount?) -> DeepSeekHistoryRequestScope
    {
        let owner = DeepSeekHistoryOwnerKey(
            cleanupRevision: self.providerCleanupRevisions[.deepseek, default: 0],
            enablementRevision: self.settings.providerEnablementRevision(for: .deepseek),
            configRevision: self.settings.providerConfigRevision(for: .deepseek),
            selectedTokenAccountID: account?.id ?? self.settings.effectiveSelectedTokenAccount(for: .deepseek)?.id,
            profileID: metadata.profileID,
            ownerTokenDigest: metadata.ownerTokenDigest,
            sourceLabel: sourceLabel)
        return DeepSeekHistoryRequestScope(
            owner: owner,
            period: metadata.plan.period,
            costUsageSettingsRevision: self.settings.costUsageSettingsRevision,
            bucketTimeZoneIdentifier: self.settings.costUsageBucketTimeZoneIdentifier,
            timeZoneSeconds: metadata.plan.timeZoneSeconds,
            anchorDayKey: metadata.plan.anchorDayKey)
    }

    private func matchesDeepSeekTransientScope(
        _ transientScope: DeepSeekTransientOptionalDetailScope,
        owner: DeepSeekHistoryOwnerKey,
        sourceLabel: String,
        account: ProviderTokenAccount?) -> Bool
    {
        let expectedAccountID = account?.id ?? self.settings.effectiveSelectedTokenAccount(for: .deepseek)?.id
        guard self.isDeepSeekHistoryOwnerCurrent(owner),
              self.settings.showOptionalCreditsAndExtraUsage,
              self.settings.isCostUsageEffectivelyEnabled(for: .deepseek),
              owner.sourceLabel == sourceLabel,
              owner.selectedTokenAccountID == expectedAccountID
        else {
            return false
        }
        if let digest = transientScope.ownerTokenDigest {
            return owner.profileID == transientScope.profileID
                && owner.ownerTokenDigest == digest
        }
        // Without a token digest (e.g. automatic browser join timeout), require an exact verified profile ID.
        guard let profileID = transientScope.profileID else { return false }
        return owner.profileID == profileID
    }

    private func isDeepSeekCompletedScopeCompatible(
        _ completedScope: DeepSeekHistoryRequestScope,
        with transientScope: DeepSeekTransientOptionalDetailScope,
        owner: DeepSeekHistoryOwnerKey) -> Bool
    {
        guard completedScope.owner == owner,
              completedScope.period == transientScope.period,
              completedScope.bucketTimeZoneIdentifier == transientScope.bucketTimeZoneIdentifier,
              self.settings.costReportingPeriod == completedScope.period,
              self.settings.costUsageSettingsRevision == completedScope.costUsageSettingsRevision,
              self.settings.costUsageBucketTimeZoneIdentifier == completedScope.bucketTimeZoneIdentifier
        else {
            return false
        }
        return self.isDeepSeekBucketDayAndOffsetCurrent(
            timeZoneSeconds: completedScope.timeZoneSeconds,
            anchorDayKey: completedScope.anchorDayKey)
    }

    private func isDeepSeekHistoryOwnerCurrent(_ owner: DeepSeekHistoryOwnerKey) -> Bool {
        self.isEnabled(.deepseek)
            && self.providerCleanupRevisions[.deepseek, default: 0] == owner.cleanupRevision
            && self.settings.providerEnablementRevision(for: .deepseek) == owner.enablementRevision
            && self.settings.providerConfigRevision(for: .deepseek) == owner.configRevision
            && self.settings.effectiveSelectedTokenAccount(for: .deepseek)?.id == owner.selectedTokenAccountID
            && self.deepseekProfileTransition == nil
    }

    private func isDeepSeekHistoryScopeCurrent(
        _ scope: DeepSeekHistoryRequestScope,
        generation: UInt64) -> Bool
    {
        guard self.deepseekHistoryGeneration == generation else { return false }
        return self.isDeepSeekHistoryScopeCurrentIgnoringGeneration(scope)
    }

    private func isDeepSeekHistoryScopeCurrentIgnoringGeneration(_ scope: DeepSeekHistoryRequestScope) -> Bool {
        guard self.isDeepSeekHistoryOwnerCurrent(scope.owner),
              self.settings.showOptionalCreditsAndExtraUsage,
              self.settings.isCostUsageEffectivelyEnabled(for: .deepseek),
              self.settings.costReportingPeriod == scope.period,
              self.settings.costUsageSettingsRevision == scope.costUsageSettingsRevision,
              self.settings.costUsageBucketTimeZoneIdentifier == scope.bucketTimeZoneIdentifier
        else {
            return false
        }
        return self.isDeepSeekBucketDayAndOffsetCurrent(
            timeZoneSeconds: scope.timeZoneSeconds,
            anchorDayKey: scope.anchorDayKey)
    }

    private func isDeepSeekScopeEligibleForMidnightRolloverReuse(
        _ scope: DeepSeekHistoryRequestScope,
        currentZoneID: String,
        currentOffset: Int) -> Bool
    {
        self.settings.costReportingPeriod == scope.period
            && self.settings.costUsageSettingsRevision == scope.costUsageSettingsRevision
            && currentZoneID == scope.bucketTimeZoneIdentifier
            && currentOffset == scope.timeZoneSeconds
    }

    private func retireDeepSeekScopesPreservingReusableChunks(_ state: inout DeepSeekHistoryRuntimeState) {
        self.cancelDeepSeekHistoryTasks()
        state.clearActive()
        state.clearCompleted()
        state.needsHeadProjection = false
        self.deepseekHistoryState = state
    }

    private func reusableDeepSeekWindowKeys(
        in state: DeepSeekHistoryRuntimeState,
        for scope: DeepSeekHistoryRequestScope) -> Set<DeepSeekUsageWindow>
    {
        guard state.owner == scope.owner,
              self.deepseekProfileTransition == nil,
              self.settings.showOptionalCreditsAndExtraUsage,
              self.settings.isCostUsageEffectivelyEnabled(for: .deepseek),
              state.chunksBucketTimeZoneIdentifier == scope.bucketTimeZoneIdentifier,
              state.chunksTimeZoneSeconds == scope.timeZoneSeconds
        else {
            return []
        }
        return Set(state.chunksByWindow.keys)
    }

    private func resolvedEffectiveDeepSeekPlan(
        incomingPlan: DeepSeekHistoryPlan,
        scope: DeepSeekHistoryRequestScope,
        state: DeepSeekHistoryRuntimeState) -> DeepSeekHistoryPlan
    {
        if state.completedScope == scope,
           let completedPlan = state.completedPlan,
           Self.isDeepSeekPlanCompatible(completedPlan, with: incomingPlan)
        {
            return completedPlan.withAnchorDate(incomingPlan.anchorDate)
        }
        if let activePlan = state.activePlan,
           Self.isDeepSeekPlanCompatible(activePlan, with: incomingPlan)
        {
            return activePlan.withAnchorDate(incomingPlan.anchorDate)
        }
        let reusableKeys = self.reusableDeepSeekWindowKeys(in: state, for: scope)
        return incomingPlan.adaptingToReusableWindows(reusableKeys)
    }

    private static func isDeepSeekPlanCompatible(
        _ existing: DeepSeekHistoryPlan,
        with incoming: DeepSeekHistoryPlan) -> Bool
    {
        existing.period == incoming.period
            && existing.anchorDayKey == incoming.anchorDayKey
            && existing.timeZoneSeconds == incoming.timeZoneSeconds
            && existing.requestedStart == incoming.requestedStart
            && existing.requestedEnd == incoming.requestedEnd
            && existing.requestedDays == incoming.requestedDays
            && existing.chunks.first == incoming.chunks.first
    }

    private func isDeepSeekBucketDayAndOffsetCurrent(timeZoneSeconds: Int, anchorDayKey: String) -> Bool {
        let now = self.deepseekHistoryNow()
        let currentOffset = self.currentDeepSeekBucketTimeZoneOffset(at: now)
        guard currentOffset == timeZoneSeconds else { return false }
        let fixedCalendar = CostUsageLocalDay.fixedOffsetGregorianCalendar(secondsFromGMT: currentOffset)
        return CostUsageLocalDay.key(from: now, calendar: fixedCalendar) == anchorDayKey
    }

    private func currentDeepSeekBucketTimeZoneOffset(at now: Date) -> Int {
        let trimmed = self.settings.costUsageBucketTimeZoneIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timeZone: TimeZone = trimmed.isEmpty ? .current : self.settings.costUsageBucketCalendar.timeZone
        return timeZone.secondsFromGMT(for: now)
    }

    private func deepseekHistoryNow() -> Date {
        #if DEBUG
        if let provider = self._test_deepseekNowProvider {
            return provider()
        }
        #endif
        return Date()
    }
}
