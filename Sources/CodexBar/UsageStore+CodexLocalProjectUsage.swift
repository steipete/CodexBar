import CodexBarCore
import Foundation

enum CodexLocalProjectUsageLoadState: Equatable {
    case idle
    case hydratingCache
    case indexing
    case stale
    case failed
}

private struct CodexLocalProjectUsageRefreshRequest: Sendable {
    let force: Bool
    let generation: UInt64
    let requestKey: String
    let now: Date
    let scopeSignature: String
    let codexHomePath: String?
    let historyDays: Int
    let hidePersonalInfo: Bool
}

private enum CodexLocalProjectUsageRefreshOutcome: Sendable {
    case success(CodexLocalProjectUsageSnapshot)
    case cancelled
    case failure
}

private enum CodexLocalProjectUsageRefreshExecutor {
    static func run(
        fetcher: CostUsageFetcher,
        request: CodexLocalProjectUsageRefreshRequest,
        progress: @escaping @Sendable (CodexLocalProjectUsageIndexProgress) -> Void)
        async -> CodexLocalProjectUsageRefreshOutcome
    {
        do {
            let snapshot = try await fetcher.loadCodexLocalProjectUsageSnapshot(
                now: request.now,
                forceRefresh: request.force,
                codexHomePath: request.codexHomePath,
                historyDays: request.historyDays,
                hidePersonalInfo: request.hidePersonalInfo,
                progress: progress)
            return .success(snapshot)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure
        }
    }
}

extension UsageStore {
    func hydrateCachedCodexLocalProjectUsage(now: Date = Date()) {
        guard self.shouldLoadCodexLocalProjectUsage else { return }
        let scope = self.tokenCostScope(for: .codex)
        let historyDays = self.settings.costUsageHistoryDays
        let hidePersonalInfo = self.settings.hidePersonalInfo
        self.codexLocalProjectUsageRequestGeneration &+= 1
        let generation = self.codexLocalProjectUsageRequestGeneration
        self.codexLocalProjectUsageLoadState = .hydratingCache
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.codexLocalProjectUsageSnapshot == nil else {
                self.codexLocalProjectUsageLoadState = .idle
                return
            }
            guard let snapshot = await self.costUsageFetcher.loadCachedCodexLocalProjectUsageSnapshot(
                now: now,
                codexHomePath: scope.codexHomePath,
                historyDays: historyDays,
                hidePersonalInfo: hidePersonalInfo)
            else {
                if self.codexLocalProjectUsageLoadState == .hydratingCache {
                    self.codexLocalProjectUsageLoadState = .idle
                }
                return
            }
            guard self.shouldLoadCodexLocalProjectUsage,
                  self.codexLocalProjectUsageRequestGeneration == generation,
                  self.tokenCostScope(for: .codex).signature == scope.signature,
                  self.settings.costUsageHistoryDays == historyDays,
                  self.settings.hidePersonalInfo == hidePersonalInfo,
                  self.codexLocalProjectUsageSnapshot == nil
            else {
                if self.codexLocalProjectUsageLoadState == .hydratingCache {
                    self.codexLocalProjectUsageLoadState = .idle
                }
                return
            }
            self.codexLocalProjectUsageSnapshot = snapshot
            self.codexLocalProjectUsageError = nil
            self.lastCodexLocalProjectUsageSuccessAt = snapshot.updatedAt
            self.codexLocalProjectUsageLoadState = .idle
        }
    }

    func scheduleCodexLocalProjectUsageRefreshIfNeeded(force: Bool = false) {
        guard self.shouldLoadCodexLocalProjectUsage else {
            self.codexLocalProjectUsageRefreshTask?.cancel()
            self.codexLocalProjectUsageRefreshTask = nil
            self.codexLocalProjectUsageSnapshot = nil
            self.codexLocalProjectUsageError = nil
            self.codexLocalProjectUsageProgress = nil
            self.codexLocalProjectUsageRefreshInFlight = false
            self.lastCodexLocalProjectUsageFetchAt = nil
            self.lastCodexLocalProjectUsageFetchScope = nil
            self.lastCodexLocalProjectUsageFailureAt = nil
            self.codexLocalProjectUsageBackoffUntil = nil
            self.codexLocalProjectUsageFailureCount = 0
            self.activeForcedCodexLocalProjectUsageRefresh = false
            self.pendingForcedCodexLocalProjectUsageRefresh = false
            self.activeCodexLocalProjectUsageRequestKey = nil
            self.pendingCodexLocalProjectUsageRequestKey = nil
            self.codexLocalProjectUsageRequestGeneration &+= 1
            self.activeCodexLocalProjectUsageRequestGeneration = nil
            self.codexLocalProjectUsageLoadState = .idle
            return
        }
        let scope = self.tokenCostScope(for: .codex)
        let requestKey = self.codexLocalProjectUsageRequestKey(
            scopeSignature: scope.signature,
            historyDays: self.settings.costUsageHistoryDays,
            hidePersonalInfo: self.settings.hidePersonalInfo)
        guard self.codexLocalProjectUsageRefreshTask == nil else {
            if self.pendingCodexLocalProjectUsageRequestKey == requestKey {
                self.pendingForcedCodexLocalProjectUsageRefresh =
                    self.pendingForcedCodexLocalProjectUsageRefresh || force
                return
            }
            if self.pendingCodexLocalProjectUsageRequestKey == nil,
               self.activeCodexLocalProjectUsageRequestKey == requestKey,
               !force || self.activeForcedCodexLocalProjectUsageRefresh
            {
                return
            }
            self.codexLocalProjectUsageRequestGeneration &+= 1
            self.pendingCodexLocalProjectUsageRequestKey = requestKey
            self.pendingForcedCodexLocalProjectUsageRefresh = force
            self.codexLocalProjectUsageRefreshTask?.cancel()
            return
        }
        self.codexLocalProjectUsageRequestGeneration &+= 1
        let generation = self.codexLocalProjectUsageRequestGeneration
        self.activeCodexLocalProjectUsageRequestKey = requestKey
        self.activeCodexLocalProjectUsageRequestGeneration = generation
        self.activeForcedCodexLocalProjectUsageRefresh = force
        let refreshExecutor = self._test_codexLocalProjectUsageRefreshExecutor
        let fetcher = self.costUsageFetcher
        let request = refreshExecutor == nil
            ? self.prepareCodexLocalProjectUsageRefresh(force: force, generation: generation, requestKey: requestKey)
            : nil
        self.codexLocalProjectUsageRefreshTask = Task { @MainActor [weak self, fetcher, refreshExecutor, request] in
            if let refreshExecutor {
                await refreshExecutor(force, generation)
            } else if let request {
                let outcome = await CodexLocalProjectUsageRefreshExecutor.run(
                    fetcher: fetcher,
                    request: request,
                    progress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.publishCodexLocalProjectUsageProgress(progress, for: request)
                        }
                    })
                guard let self else { return }
                self.applyCodexLocalProjectUsageRefreshOutcome(outcome, for: request)
            }
            guard let self else { return }
            self.finishCodexLocalProjectUsageRefresh(generation: generation)
        }
    }

    func refreshCodexLocalProjectUsageProjectionIfNeeded(previousHidePersonalInfo: Bool) {
        let hidePersonalInfo = self.settings.hidePersonalInfo
        guard previousHidePersonalInfo != hidePersonalInfo else { return }
        if hidePersonalInfo {
            self.codexLocalProjectUsageSnapshot = nil
            self.codexLocalProjectUsageError = nil
            self.codexLocalProjectUsageProgress = nil
            self.codexLocalProjectUsageRefreshInFlight = false
            self.codexLocalProjectUsageLoadState = .idle
            self.lastCodexLocalProjectUsageFetchAt = nil
            self.lastCodexLocalProjectUsageFetchScope = nil
            self.lastCodexLocalProjectUsageFailureAt = nil
            self.codexLocalProjectUsageBackoffUntil = nil
            self.codexLocalProjectUsageFailureCount = 0
        }
        self.scheduleCodexLocalProjectUsageRefreshIfNeeded()
    }

    func refreshCodexLocalProjectUsageAvailabilityIfNeeded(previousEnabled: Bool) {
        guard previousEnabled != self.settings.codexLocalProjectUsageEnabled else { return }
        self.scheduleCodexLocalProjectUsageRefreshIfNeeded()
    }

    private func prepareCodexLocalProjectUsageRefresh(
        force: Bool,
        generation: UInt64,
        requestKey: String) -> CodexLocalProjectUsageRefreshRequest?
    {
        guard generation == self.codexLocalProjectUsageRequestGeneration else { return nil }
        guard self.shouldLoadCodexLocalProjectUsage else { return nil }
        if self.codexLocalProjectUsageRefreshInFlight { return nil }

        let now = Date()
        let historyDays = self.settings.costUsageHistoryDays
        let hidePersonalInfo = self.settings.hidePersonalInfo
        let scope = self.tokenCostScope(for: .codex)
        let scopeSignature = self.codexLocalProjectUsageRequestKey(
            scopeSignature: scope.signature,
            historyDays: historyDays,
            hidePersonalInfo: hidePersonalInfo)
        if !force,
           let last = self.lastCodexLocalProjectUsageFetchAt,
           self.lastCodexLocalProjectUsageFetchScope == scopeSignature,
           now.timeIntervalSince(last) < Self.codexLocalProjectUsageRefreshTTL
        {
            return nil
        }
        if !force, let backoffUntil = self.codexLocalProjectUsageBackoffUntil, now < backoffUntil {
            return nil
        }

        self.lastCodexLocalProjectUsageFetchScope = scopeSignature
        self.lastCodexLocalProjectUsageAttemptAt = now
        self.codexLocalProjectUsageRefreshInFlight = true
        self.codexLocalProjectUsageLoadState = .indexing
        self.codexLocalProjectUsageProgress = CodexLocalProjectUsageIndexProgress(phase: .scanningLogs)

        return CodexLocalProjectUsageRefreshRequest(
            force: force,
            generation: generation,
            requestKey: requestKey,
            now: now,
            scopeSignature: scope.signature,
            codexHomePath: scope.codexHomePath,
            historyDays: historyDays,
            hidePersonalInfo: hidePersonalInfo)
    }

    private func publishCodexLocalProjectUsageProgress(
        _ progress: CodexLocalProjectUsageIndexProgress,
        for request: CodexLocalProjectUsageRefreshRequest)
    {
        guard self.isActiveCodexLocalProjectUsageRefresh(request) else { return }
        self.codexLocalProjectUsageProgress = progress
    }

    private func applyCodexLocalProjectUsageRefreshOutcome(
        _ outcome: CodexLocalProjectUsageRefreshOutcome,
        for request: CodexLocalProjectUsageRefreshRequest)
    {
        guard self.isActiveCodexLocalProjectUsageRefresh(request) else { return }
        switch outcome {
        case let .success(snapshot):
            self.codexLocalProjectUsageSnapshot = snapshot
            self.codexLocalProjectUsageError = nil
            self.lastCodexLocalProjectUsageFetchAt = request.now
            self.lastCodexLocalProjectUsageSuccessAt = request.now
            self.lastCodexLocalProjectUsageFailureAt = nil
            self.codexLocalProjectUsageBackoffUntil = nil
            self.codexLocalProjectUsageFailureCount = 0
        case .cancelled:
            break
        case .failure:
            self.codexLocalProjectUsageError = L("codex_workspaces_failed_read_logs")
            self.lastCodexLocalProjectUsageFailureAt = request.now
            self.codexLocalProjectUsageFailureCount += 1
            let backoff = min(30.0 * pow(2, Double(self.codexLocalProjectUsageFailureCount - 1)), 15 * 60)
            self.codexLocalProjectUsageBackoffUntil = request.now.addingTimeInterval(backoff)
            self.codexLocalProjectUsageLoadState = self.codexLocalProjectUsageSnapshot == nil ? .failed : .stale
        }
    }

    private func isActiveCodexLocalProjectUsageRefresh(_ request: CodexLocalProjectUsageRefreshRequest) -> Bool {
        self.activeCodexLocalProjectUsageRequestGeneration == request.generation &&
            self.codexLocalProjectUsageRequestGeneration == request.generation &&
            self.activeCodexLocalProjectUsageRequestKey == request.requestKey &&
            self.codexLocalProjectUsageRefreshInFlight &&
            self.shouldLoadCodexLocalProjectUsage &&
            self.tokenCostScope(for: .codex).signature == request.scopeSignature &&
            self.settings.costUsageHistoryDays == request.historyDays &&
            self.settings.hidePersonalInfo == request.hidePersonalInfo
    }

    private func finishCodexLocalProjectUsageRefresh(generation: UInt64) {
        guard self.activeCodexLocalProjectUsageRequestGeneration == generation else { return }
        self.codexLocalProjectUsageRefreshInFlight = false
        self.codexLocalProjectUsageProgress = nil
        if self.codexLocalProjectUsageLoadState == .indexing {
            self.codexLocalProjectUsageLoadState = .idle
        }
        self.codexLocalProjectUsageRefreshTask = nil
        self.activeCodexLocalProjectUsageRequestKey = nil
        self.activeCodexLocalProjectUsageRequestGeneration = nil
        self.activeForcedCodexLocalProjectUsageRefresh = false
        if self.pendingCodexLocalProjectUsageRequestKey != nil {
            let pendingForce = self.pendingForcedCodexLocalProjectUsageRefresh
            self.pendingCodexLocalProjectUsageRequestKey = nil
            self.pendingForcedCodexLocalProjectUsageRefresh = false
            self.scheduleCodexLocalProjectUsageRefreshIfNeeded(force: pendingForce)
        }
    }

    private func codexLocalProjectUsageRequestKey(
        scopeSignature: String,
        historyDays: Int,
        hidePersonalInfo: Bool) -> String
    {
        "\(scopeSignature)|historyDays=\(historyDays)|hidePersonalInfo=\(hidePersonalInfo)"
    }

    func rebuildCodexLocalProjectUsageIndex() {
        guard self.shouldLoadCodexLocalProjectUsage else { return }
        self.codexLocalProjectUsageError = nil
        self.lastCodexLocalProjectUsageFetchAt = nil
        self.lastCodexLocalProjectUsageFetchScope = nil
        self.lastCodexLocalProjectUsageFailureAt = nil
        self.codexLocalProjectUsageBackoffUntil = nil
        self.codexLocalProjectUsageFailureCount = 0
        self.scheduleCodexLocalProjectUsageRefreshIfNeeded(force: true)
    }

    var codexLocalProjectUsageRowSubtitle: String? {
        if self.codexLocalProjectUsageRefreshInFlight {
            return L("codex_workspaces_indexing_local_logs")
        }
        guard let snapshot = self.codexLocalProjectUsageSnapshot else {
            if self.codexLocalProjectUsageError != nil {
                return L("codex_workspaces_failed_read_logs")
            }
            return nil
        }
        if snapshot.sourceStatus.isPartial {
            return L("codex_workspaces_failed_some_logs")
        }
        let age = Date().timeIntervalSince(snapshot.updatedAt)
        guard age >= Self.codexLocalProjectUsageStaleAge else {
            if self.codexLocalProjectUsageError != nil {
                return L("codex_workspaces_failed_read_logs")
            }
            return nil
        }
        if self.codexLocalProjectUsageError != nil {
            return L("codex_workspaces_failed_read_logs")
        }
        return L("codex_workspaces_stale_status", Self.formatDuration(age))
    }

    var codexLocalProjectUsageProgressSubtitle: String? {
        guard let progress = self.codexLocalProjectUsageProgress else { return nil }
        return Self.formatCodexLocalProjectUsageProgress(progress)
    }

    var codexLocalProjectUsageProgressFraction: Double? {
        guard let progress = self.codexLocalProjectUsageProgress,
              progress.phase == .indexingProjects,
              let processed = progress.processedFileCount,
              let total = progress.totalFileCount,
              total > 0
        else {
            return nil
        }
        return min(1, max(0, Double(processed) / Double(total)))
    }

    func codexLocalProjectUsageDisplayTotal(_ totals: CodexLocalUsageTotals) -> Int? {
        self.codexLocalProjectUsageProjection.displayedTokens(for: totals)
    }

    func codexLocalProjectUsageDailyDisplayTotal(_ point: CodexLocalUsageDailyPoint) -> Int {
        self.codexLocalProjectUsageProjection.displayedTokens(
            totalTokens: point.totalTokens,
            cachedInputTokens: point.cachedInputTokens)
    }

    func codexLocalProjectUsageRankedProjects(_ projects: [CodexLocalProjectUsage]) -> [CodexLocalProjectUsage] {
        self.codexLocalProjectUsageProjection.rankedProjects(projects)
    }

    var codexLocalProjectUsageProjection: CodexLocalProjectUsageProjection {
        CodexLocalProjectUsageProjection(
            includesCachedInput: self.settings.codexLocalProjectUsageIncludesCachedInput,
            showsEstimatedCost: self.settings.codexLocalProjectUsageShowsEstimatedCost)
    }

    private var shouldLoadCodexLocalProjectUsage: Bool {
        self.settings.codexLocalProjectUsageEnabled &&
            self.isEnabled(.codex)
    }

    private static let codexLocalProjectUsageRefreshTTL: TimeInterval = 60 * 60
    private static let codexLocalProjectUsageFailureBackoff: TimeInterval = 5 * 60
    private static let codexLocalProjectUsageStaleAge: TimeInterval = 2 * 60 * 60

    private static func formatCodexLocalProjectUsageProgress(
        _ progress: CodexLocalProjectUsageIndexProgress) -> String
    {
        switch progress.phase {
        case .scanningLogs:
            return L("codex_workspaces_scanning_logs")
        case .indexingProjects:
            guard let processed = progress.processedFileCount,
                  let total = progress.totalFileCount,
                  total > 0
            else {
                return L("codex_workspaces_indexing_projects")
            }
            let clampedProcessed = min(max(0, processed), total)
            let remaining = max(0, total - clampedProcessed)
            if remaining == 0 {
                return L("codex_workspaces_finalizing_project_index_files", total)
            }
            return L("codex_workspaces_indexing_projects_files_left", clampedProcessed, total, remaining)
        case .saving:
            return L("codex_workspaces_saving_project_index")
        }
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int(interval / 60))
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(remainingMinutes)m"
    }
}
