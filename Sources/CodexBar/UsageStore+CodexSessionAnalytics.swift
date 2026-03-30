import AppKit
import CodexBarCore
import Foundation

extension UsageStore {
    func codexSessionAnalyticsSnapshot() -> CodexSessionAnalyticsSnapshot? {
        self.codexSessionAnalytics
    }

    func lastCodexSessionAnalyticsError() -> String? {
        self.codexSessionAnalyticsError
    }

    func codexSessionAnalyticsStatusText() -> String {
        if self.codexSessionAnalyticsIsRefreshing {
            return self.codexSessionAnalytics == nil ? "Building local analytics…" : "Refreshing…"
        }

        if let generatedAt = self.codexSessionAnalytics?.generatedAt ?? self
            .codexSessionAnalyticsLastSuccessfulRefreshAt
        {
            return "Updated \(generatedAt.relativeDescription())"
        }

        return "No cached analytics yet"
    }

    func bootstrapCodexSessionAnalyticsCache() {
        guard let index = self.codexSessionAnalyticsIndexer.loadPersistedIndex() else {
            self.codexSessionAnalyticsIndex = CodexSessionAnalyticsIndex(dirty: true)
            self.codexSessionAnalyticsDirty = true
            self.codexSessionAnalytics = nil
            return
        }

        self.applyCodexSessionAnalyticsIndex(index, now: index.lastSuccessfulRefreshAt ?? .now)
        self.codexSessionAnalyticsError = nil
    }

    func requestCodexSessionAnalyticsRefreshIfStale(reason: String) {
        self.codexSessionAnalyticsLastInteractionAt = Date()
        self.applyCodexSessionAnalyticsSnapshot(
            windowSize: self.settings.codexSessionAnalyticsWindowSize,
            preserveExisting: false)
        self.startCodexSessionAnalyticsWatcherIfNeeded()

        guard self.shouldRefreshCodexSessionAnalyticsOnInteraction() else { return }
        self.scheduleCodexSessionAnalyticsRefresh(reason: reason)
    }

    func refreshCodexSessionAnalyticsIfNeeded(force: Bool = false) {
        self.codexSessionAnalyticsLastInteractionAt = Date()
        self.applyCodexSessionAnalyticsSnapshot(windowSize: self.settings.codexSessionAnalyticsWindowSize)
        self.startCodexSessionAnalyticsWatcherIfNeeded()

        if force {
            self.scheduleCodexSessionAnalyticsRefresh(reason: "forced refresh", force: true)
            return
        }

        guard self.shouldRefreshCodexSessionAnalyticsOnInteraction() else { return }
        self.scheduleCodexSessionAnalyticsRefresh(reason: "manual refresh")
    }

    func updateCodexSessionAnalyticsBackgroundWork() {
        guard self.startupBehavior.automaticallyStartsBackgroundWork, self.isEnabled(.codex) else {
            self.codexSessionAnalyticsWarmupTask?.cancel()
            self.codexSessionAnalyticsWarmupTask = nil
            self.codexSessionAnalyticsWatcher = nil
            return
        }

        self.startCodexSessionAnalyticsWatcherIfNeeded()

        guard self.codexSessionAnalyticsRefreshTask == nil else { return }
        guard self.codexSessionAnalyticsIndex == nil ||
            self.codexSessionAnalyticsDirty ||
            self.isCodexSessionAnalyticsValidationDue()
        else { return }

        self.scheduleCodexSessionAnalyticsRefresh(
            reason: "startup warmup",
            delay: self.codexSessionAnalyticsStartupWarmupDelay)
    }

    func handleCodexSessionAnalyticsWatcherEvent() {
        self.codexSessionAnalyticsDirty = true

        guard self.startupBehavior.automaticallyStartsBackgroundWork, self.isEnabled(.codex) else { return }
        guard NSApp?.isActive == true else { return }

        self.scheduleCodexSessionAnalyticsRefresh(
            reason: "filesystem change",
            delay: self.codexSessionAnalyticsRefreshDebounce)
    }

    private func shouldRefreshCodexSessionAnalyticsOnInteraction() -> Bool {
        if self.codexSessionAnalyticsRefreshTask != nil {
            return false
        }

        if self.codexSessionAnalyticsIndex == nil || self.codexSessionAnalyticsDirty {
            return true
        }

        return self.isCodexSessionAnalyticsValidationDue()
    }

    private func isCodexSessionAnalyticsValidationDue(now: Date = .now) -> Bool {
        guard let lastSuccessfulRefreshAt = self.codexSessionAnalyticsLastSuccessfulRefreshAt ??
            self.codexSessionAnalyticsIndex?.lastSuccessfulRefreshAt
        else {
            return true
        }

        return now.timeIntervalSince(lastSuccessfulRefreshAt) > self.codexSessionAnalyticsValidationInterval
    }

    private func startCodexSessionAnalyticsWatcherIfNeeded() {
        guard self.startupBehavior.automaticallyStartsBackgroundWork, self.isEnabled(.codex) else { return }

        let roots = self.codexSessionAnalyticsIndexer.watchRoots()
        let watchedPaths = roots.map(\.path).sorted()

        if self.codexSessionAnalyticsWatcher?.watchedPaths == watchedPaths {
            return
        }

        let watcher = CodexSessionsWatcher(urls: roots) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleCodexSessionAnalyticsWatcherEvent()
            }
        }

        self.codexSessionAnalyticsWatcher = watcher.isWatching ? watcher : nil
    }

    private func scheduleCodexSessionAnalyticsRefresh(
        reason _: String,
        delay: Duration? = nil,
        force: Bool = false)
    {
        if force {
            self.codexSessionAnalyticsWarmupTask?.cancel()
            self.codexSessionAnalyticsWarmupTask = nil
            self.codexSessionAnalyticsRefreshTask?.cancel()
            self.codexSessionAnalyticsRefreshTask = nil
            self.codexSessionAnalyticsRefreshToken = nil
        } else {
            if self.codexSessionAnalyticsRefreshTask != nil {
                return
            }
            if delay != nil, self.codexSessionAnalyticsWarmupTask != nil {
                return
            }
        }

        guard delay != nil || self.codexSessionAnalyticsRefreshTask == nil else { return }

        if let delay {
            self.codexSessionAnalyticsWarmupTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self.codexSessionAnalyticsWarmupTask = nil
                self.startCodexSessionAnalyticsRefreshTask()
            }
            return
        }

        self.startCodexSessionAnalyticsRefreshTask()
    }

    private func startCodexSessionAnalyticsRefreshTask() {
        guard self.codexSessionAnalyticsRefreshTask == nil else { return }

        self.codexSessionAnalyticsWarmupTask?.cancel()
        self.codexSessionAnalyticsWarmupTask = nil
        self.codexSessionAnalyticsIsRefreshing = true

        let refreshToken = UUID()
        self.codexSessionAnalyticsRefreshToken = refreshToken

        let existingIndex = self.codexSessionAnalyticsIndex
        let indexer = self.codexSessionAnalyticsIndexer
        let windowSizes = Self.codexSessionAnalyticsWindowSizes(current: self.settings.codexSessionAnalyticsWindowSize)
        let backgroundTask = Task.detached(priority: .utility) {
            let refreshStartedAt = Date()

            do {
                let index = try indexer.refreshIndex(existing: existingIndex, now: refreshStartedAt)
                let snapshots = CodexSessionAnalyticsSnapshotBuilder.buildSnapshots(
                    from: index,
                    windowSizes: windowSizes,
                    now: refreshStartedAt)
                return CodexSessionAnalyticsRefreshResult(
                    index: index,
                    snapshots: snapshots,
                    error: nil,
                    refreshAt: refreshStartedAt)
            } catch {
                return CodexSessionAnalyticsRefreshResult(
                    index: nil,
                    snapshots: nil,
                    error: error.localizedDescription,
                    refreshAt: refreshStartedAt)
            }
        }

        self.codexSessionAnalyticsRefreshTask = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler(
                operation: {
                    await backgroundTask.value
                },
                onCancel: {
                    backgroundTask.cancel()
                })

            guard let self else { return }
            guard !Task.isCancelled else { return }
            self.finishCodexSessionAnalyticsRefresh(
                token: refreshToken,
                index: result.index,
                snapshots: result.snapshots,
                error: result.error,
                refreshAt: result.refreshAt)
        }
    }

    private func finishCodexSessionAnalyticsRefresh(
        token: UUID,
        index: CodexSessionAnalyticsIndex?,
        snapshots: [Int: CodexSessionAnalyticsSnapshot]?,
        error: String?,
        refreshAt: Date)
    {
        guard self.codexSessionAnalyticsRefreshToken == token else { return }

        self.codexSessionAnalyticsRefreshTask = nil
        self.codexSessionAnalyticsRefreshToken = nil
        self.codexSessionAnalyticsIsRefreshing = false

        if let index, let snapshots {
            self.codexSessionAnalyticsIndex = index
            self.codexSessionAnalyticsDirty = false
            self.codexSessionAnalyticsLastSuccessfulRefreshAt = index.lastSuccessfulRefreshAt ?? refreshAt
            self.codexSessionAnalyticsCacheByWindow = snapshots
            self.lastCodexSessionAnalyticsRefreshAt = self.codexSessionAnalyticsLastSuccessfulRefreshAt
            self.lastCodexSessionAnalyticsRefreshAtByWindow = Dictionary(
                uniqueKeysWithValues: snapshots.keys.map {
                    ($0, self.codexSessionAnalyticsLastSuccessfulRefreshAt ?? refreshAt)
                })
            self.codexSessionAnalyticsError = nil
            self.codexSessionAnalyticsErrorCacheByWindow.removeAll()
            self.applyCodexSessionAnalyticsSnapshot(
                windowSize: self.settings.codexSessionAnalyticsWindowSize,
                preserveExisting: false)
            return
        }

        self.codexSessionAnalyticsDirty = true
        self.codexSessionAnalyticsError = error
        if let error {
            for windowSize in Self
                .codexSessionAnalyticsWindowSizes(current: self.settings.codexSessionAnalyticsWindowSize)
            {
                self.codexSessionAnalyticsErrorCacheByWindow[windowSize] = error
            }
        }
        self.applyCodexSessionAnalyticsSnapshot(windowSize: self.settings.codexSessionAnalyticsWindowSize)
    }

    private func applyCodexSessionAnalyticsIndex(_ index: CodexSessionAnalyticsIndex, now: Date) {
        self.codexSessionAnalyticsIndex = index
        self.codexSessionAnalyticsDirty = index.dirty
        self.codexSessionAnalyticsLastSuccessfulRefreshAt = index.lastSuccessfulRefreshAt ?? now
        self.codexSessionAnalyticsCacheByWindow = CodexSessionAnalyticsSnapshotBuilder.buildSnapshots(
            from: index,
            windowSizes: Self.codexSessionAnalyticsWindowSizes(current: self.settings.codexSessionAnalyticsWindowSize),
            now: now)
        self.lastCodexSessionAnalyticsRefreshAt = self.codexSessionAnalyticsLastSuccessfulRefreshAt
        self.lastCodexSessionAnalyticsRefreshAtByWindow = Dictionary(
            uniqueKeysWithValues: self.codexSessionAnalyticsCacheByWindow.keys.map {
                ($0, self.codexSessionAnalyticsLastSuccessfulRefreshAt ?? now)
            })
        self.applyCodexSessionAnalyticsSnapshot(windowSize: self.settings.codexSessionAnalyticsWindowSize)
    }

    private func applyCodexSessionAnalyticsSnapshot(windowSize: Int, preserveExisting: Bool = true) {
        let existingSnapshot = self.codexSessionAnalytics
        self.codexSessionAnalytics = self.codexSessionAnalyticsCacheByWindow[windowSize]
        if self.codexSessionAnalytics == nil {
            self.codexSessionAnalytics = self.codexSessionAnalyticsCacheByWindow.values
                .max { lhs, rhs in
                    lhs.sessionsAnalyzed < rhs.sessionsAnalyzed
                }
        }
        if preserveExisting, self.codexSessionAnalytics == nil {
            self.codexSessionAnalytics = existingSnapshot
        }
    }

    private static func codexSessionAnalyticsWindowSizes(current: Int) -> [Int] {
        Array(Set(SettingsStore.codexSessionAnalyticsWindowPresets + [current])).sorted()
    }
}

private struct CodexSessionAnalyticsRefreshResult: Sendable {
    let index: CodexSessionAnalyticsIndex?
    let snapshots: [Int: CodexSessionAnalyticsSnapshot]?
    let error: String?
    let refreshAt: Date
}
