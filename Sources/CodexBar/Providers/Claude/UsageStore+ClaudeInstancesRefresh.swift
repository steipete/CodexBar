import CodexBarCore
import Foundation

typealias ClaudeInstanceUsageLoader = @Sendable (ClaudeInstanceConfig) async throws -> UsageSnapshot

/// Observed instance-card state, kept in one stored `UsageStore` property.
struct ClaudeInstanceState {
    var accountSnapshots: [ProviderAccountUsageSnapshot] = []
    var revision: UInt64 = 0
    var lastRefreshAt: Date?
}

/// Unobserved refresh plumbing for instance cards.
struct ClaudeInstanceRefreshHandle {
    var task: Task<Void, Never>?
    #if DEBUG
    var usageLoaderOverride: ClaudeInstanceUsageLoader?
    #endif
}

extension UsageStore {
    var claudeInstanceAccountSnapshots: [ProviderAccountUsageSnapshot] {
        get { self.claudeInstanceState.accountSnapshots }
        set { self.claudeInstanceState.accountSnapshots = newValue }
    }

    var claudeInstanceRevision: UInt64 {
        get { self.claudeInstanceState.revision }
        set { self.claudeInstanceState.revision = newValue }
    }

    var claudeInstanceLastRefreshAt: Date? {
        get { self.claudeInstanceState.lastRefreshAt }
        set { self.claudeInstanceState.lastRefreshAt = newValue }
    }

    var claudeInstanceRefreshTask: Task<Void, Never>? {
        get { self.claudeInstanceRefresh.task }
        set { self.claudeInstanceRefresh.task = newValue }
    }

    #if DEBUG
    var claudeInstanceUsageLoaderOverride: ClaudeInstanceUsageLoader? {
        get { self.claudeInstanceRefresh.usageLoaderOverride }
        set { self.claudeInstanceRefresh.usageLoaderOverride = newValue }
    }
    #endif

    /// claude-swap first, then Claude instances; nil keeps the ambient Claude snapshot.
    func claudeAccountSourceMenuBarSnapshotOverride(for instanceID: ProviderInstanceID) -> UsageSnapshot? {
        self.claudeSwapMenuBarSnapshotOverride(for: instanceID)
            ?? self.claudeInstanceMenuBarSnapshotOverride(for: instanceID)
    }
}

extension UsageStore {
    func shouldFetchClaudeInstances() -> Bool {
        self.isEnabled(.claude) && self.settings.claudeInstancesEnabled && !self.settings.claudeInstances.isEmpty
    }

    /// Instance cards replace the ambient Claude card once the feature is on and any instance has reported.
    var claudeInstancesOwnAccountPresentation: Bool {
        self.settings.claudeInstancesEnabled && !self.claudeInstanceAccountSnapshots.isEmpty
    }

    /// The first instance with usable usage drives the menu bar so the indicator agrees with the menu cards.
    func claudeInstanceMenuBarSnapshotOverride(for instanceID: ProviderInstanceID) -> UsageSnapshot? {
        guard instanceID == UsageProvider.claude.instanceID, self.claudeInstancesOwnAccountPresentation else {
            return nil
        }
        return self.claudeInstanceAccountSnapshots.lazy.compactMap(\.snapshot).first
    }

    func clearClaudeInstanceState() {
        let hadState = !self.claudeInstanceAccountSnapshots.isEmpty || self.claudeInstanceLastRefreshAt != nil
        self.claudeInstanceRefreshTask?.cancel()
        self.claudeInstanceRefreshTask = nil
        self.claudeInstanceAccountSnapshots = []
        self.claudeInstanceLastRefreshAt = nil
        if hadState {
            self.claudeInstanceRevision &+= 1
        }
    }

    /// Runs separately from the ambient Claude refresh so slow instance probes never delay it.
    func scheduleClaudeInstanceRefresh(generation: UInt64? = nil) {
        self.claudeInstanceRefreshTask?.cancel()
        guard self.shouldFetchClaudeInstances() else {
            self.clearClaudeInstanceState()
            return
        }

        self.claudeInstanceRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshClaudeInstances(generation: generation)
        }
    }

    /// Probes run one at a time: the shared Claude CLI session relaunches for each profile, and overlapping probes
    /// would tear down each other's session. Each finished instance is published immediately.
    func refreshClaudeInstances(generation: UInt64? = nil) async {
        let instances = self.settings.claudeInstances
        let loader = self.claudeInstanceUsageLoader()
        let previousByID = Dictionary(
            self.claudeInstanceAccountSnapshots.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var refreshedByID: [ProviderAccountIdentity: ProviderAccountUsageSnapshot] = [:]

        for (index, instance) in instances.enumerated() {
            let result: Result<UsageSnapshot, Error>
            do {
                result = try await .success(loader(instance))
            } catch is CancellationError {
                return
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled,
                  self.isCurrentClaudeInstanceRefresh(instances: instances, generation: generation)
            else { return }

            let id = ClaudeInstanceAccountProjection.identity(for: instance)
            refreshedByID[id] = ClaudeInstanceAccountProjection.accountSnapshot(
                for: instance,
                index: index,
                result: result,
                previous: previousByID[id])
            self.claudeInstanceAccountSnapshots = instances.compactMap { instance in
                let id = ClaudeInstanceAccountProjection.identity(for: instance)
                return refreshedByID[id] ?? previousByID[id]
            }
            self.claudeInstanceRevision &+= 1
        }
        self.claudeInstanceLastRefreshAt = Date()
    }

    private func claudeInstanceUsageLoader() -> ClaudeInstanceUsageLoader {
        #if DEBUG
        if let override = self.claudeInstanceUsageLoaderOverride {
            return override
        }
        #endif
        let baseEnvironment = self.environmentBase
        let browserDetection = self.browserDetection
        let keepCLISessionsAlive = self.settings.debugKeepCLISessionsAlive
        return { instance in
            try await ClaudeInstanceUsageFetcher.fetchUsage(
                for: instance,
                baseEnvironment: baseEnvironment,
                browserDetection: browserDetection,
                keepCLISessionsAlive: keepCLISessionsAlive)
        }
    }

    private func isCurrentClaudeInstanceRefresh(instances: [ClaudeInstanceConfig], generation: UInt64?) -> Bool {
        self.isCurrentProviderRefreshGeneration(.claude, generation: generation) &&
            self.isEnabled(.claude) && self.settings.claudeInstancesEnabled &&
            self.settings.claudeInstances == instances
    }
}
