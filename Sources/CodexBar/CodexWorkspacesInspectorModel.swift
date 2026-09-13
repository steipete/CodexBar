import CodexBarCore
import Foundation
import Observation

/// Window-local state for the opt-in Codex Workspaces inspector.
///
/// The model deliberately owns only transient presentation state. Snapshot
/// loading remains with `CostUsageFetcher`; settings and cache ownership stay
/// outside the window so this view cannot accidentally mutate shared state.
@MainActor
@Observable
final class CodexWorkspacesInspectorModel {
    enum LoadReason: Equatable {
        case initial
        case inspectorDetail
        case refresh
    }

    struct Configuration: Sendable, Equatable {
        let codexHomePath: String?
        let scopeSignature: String
        let historyDays: Int
        let hidePersonalInfo: Bool
    }

    typealias CachedSnapshotLoader = @Sendable (Configuration) async -> CodexLocalProjectUsageSnapshot?
    typealias SnapshotLoader = @Sendable (
        Configuration,
        Bool,
        @escaping @Sendable (CodexLocalProjectUsageIndexProgress) -> Void)
        async throws -> CodexLocalProjectUsageSnapshot
    typealias ProjectIDRanker = @Sendable (CodexLocalProjectUsageSnapshot) -> [String]

    private(set) var snapshot: CodexLocalProjectUsageSnapshot?
    private(set) var progress: CodexLocalProjectUsageIndexProgress?
    private(set) var isLoading = false
    private(set) var loadReason: LoadReason?
    private(set) var hasLoadFailure = false
    private(set) var selectedProjectID: String?
    private(set) var selectedSessionID: String?

    private var configuration: Configuration
    @ObservationIgnored private let cachedSnapshotLoader: CachedSnapshotLoader
    @ObservationIgnored private let snapshotLoader: SnapshotLoader
    @ObservationIgnored private let projectIDRanker: ProjectIDRanker
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var requestGeneration = 0

    var hidesPersonalInfo: Bool {
        self.configuration.hidePersonalInfo
    }

    convenience init(
        configuration: Configuration,
        fetcher: CostUsageFetcher = CostUsageFetcher(),
        projectIDRanker: @escaping ProjectIDRanker = { snapshot in
            CodexWorkspacesInspectorPresentation.projection.rankedProjects(snapshot.projects).map(\.id)
        })
    {
        self.init(
            configuration: configuration,
            cachedSnapshotLoader: { configuration in
                await fetcher.loadCachedCodexLocalProjectUsageSnapshot(
                    codexHomePath: configuration.codexHomePath,
                    historyDays: configuration.historyDays,
                    hidePersonalInfo: configuration.hidePersonalInfo)
            },
            snapshotLoader: { configuration, forceRefresh, progress in
                try await fetcher.loadCodexLocalProjectUsageSnapshot(
                    forceRefresh: forceRefresh,
                    codexHomePath: configuration.codexHomePath,
                    historyDays: configuration.historyDays,
                    hidePersonalInfo: configuration.hidePersonalInfo,
                    progress: progress)
            },
            projectIDRanker: projectIDRanker)
    }

    init(
        configuration: Configuration,
        cachedSnapshotLoader: @escaping CachedSnapshotLoader,
        snapshotLoader: @escaping SnapshotLoader,
        projectIDRanker: @escaping ProjectIDRanker = { snapshot in
            CodexWorkspacesInspectorPresentation.projection.rankedProjects(snapshot.projects).map(\.id)
        })
    {
        self.configuration = configuration
        self.cachedSnapshotLoader = cachedSnapshotLoader
        self.snapshotLoader = snapshotLoader
        self.projectIDRanker = projectIDRanker
    }

    deinit {
        self.loadTask?.cancel()
    }

    /// Starts the normal cache-first open path. Repeated view updates share the
    /// active task, and reopening valid content does not begin an equivalent scan.
    func load() {
        guard self.loadTask == nil, self.snapshot == nil else { return }
        self.beginLoad(preferCachedSnapshot: true, forceRefresh: false)
    }

    /// Bypasses the cache path and asks the fetcher to rescan source data.
    func refresh() {
        guard self.loadTask == nil else { return }
        self.beginLoad(preferCachedSnapshot: false, forceRefresh: true)
    }

    /// Cancels only this window's request. Previously displayed content remains
    /// useful while a later load is pending or after a cancellation.
    func cancelLoading() {
        self.invalidateCurrentLoad()
        self.isLoading = false
        self.loadReason = nil
        self.progress = nil
    }

    /// Configuration identifies a privacy and source scope boundary. Clearing
    /// immediately prevents a previous account or privacy mode from rendering
    /// while the next scope loads.
    func updateConfiguration(_ configuration: Configuration) {
        guard configuration != self.configuration else { return }

        self.invalidateCurrentLoad()
        self.configuration = configuration
        self.snapshot = nil
        self.progress = nil
        self.isLoading = false
        self.loadReason = nil
        self.hasLoadFailure = false
        self.selectedProjectID = nil
        self.selectedSessionID = nil
    }

    func selectProject(id: String?) {
        if id != self.selectedProjectID {
            self.selectedSessionID = nil
        }
        self.selectedProjectID = id
        self.reconcileSelectionState()
    }

    func selectSession(id: String?) {
        guard let id, let snapshot else {
            self.selectedSessionID = nil
            return
        }
        let belongsToSelectedProject = self.sessions(in: snapshot).contains {
            $0.id == id && $0.projectId == self.selectedProjectID
        }
        self.selectedSessionID = belongsToSelectedProject ? id : nil
    }

    /// Lets the view reconcile after its fixed projection settings change
    /// without making the model depend on SettingsStore or projection policy.
    func reconcileSelections(rankedProjectIDs: [String]) {
        self.reconcileSelectionState(rankedProjectIDs: rankedProjectIDs)
    }

    func waitForCurrentLoad() async {
        await self.loadTask?.value
    }

    private func beginLoad(preferCachedSnapshot: Bool, forceRefresh: Bool) {
        self.requestGeneration &+= 1
        let generation = self.requestGeneration
        let configuration = self.configuration
        let cachedSnapshotLoader = self.cachedSnapshotLoader
        let snapshotLoader = self.snapshotLoader

        self.isLoading = true
        self.loadReason = forceRefresh ? .refresh : .initial
        self.progress = nil
        self.hasLoadFailure = false

        self.loadTask = Task { @MainActor [weak self] in
            if preferCachedSnapshot {
                let cachedSnapshot = await cachedSnapshotLoader(configuration)
                guard !Task.isCancelled else {
                    self?.finishLoading(generation: generation, configuration: configuration)
                    return
                }
                if let cachedSnapshot, Self.hasInspectorDetail(cachedSnapshot) {
                    self?.publish(
                        cachedSnapshot,
                        generation: generation,
                        configuration: configuration)
                    return
                }
                if cachedSnapshot != nil {
                    self?.markInspectorDetailLoad(generation: generation, configuration: configuration)
                }
            }

            let progressHandler: @Sendable (CodexLocalProjectUsageIndexProgress) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.receive(progress, generation: generation, configuration: configuration)
                }
            }

            do {
                let loadedSnapshot = try await snapshotLoader(configuration, forceRefresh, progressHandler)
                guard !Task.isCancelled else {
                    self?.finishLoading(generation: generation, configuration: configuration)
                    return
                }
                self?.publish(loadedSnapshot, generation: generation, configuration: configuration)
            } catch {
                self?.failLoading(generation: generation, configuration: configuration)
            }
        }
    }

    private func invalidateCurrentLoad() {
        self.requestGeneration &+= 1
        self.loadTask?.cancel()
        self.loadTask = nil
    }

    private func receive(
        _ progress: CodexLocalProjectUsageIndexProgress,
        generation: Int,
        configuration: Configuration)
    {
        guard self.isCurrent(generation: generation, configuration: configuration) else { return }
        self.progress = progress
    }

    private func markInspectorDetailLoad(generation: Int, configuration: Configuration) {
        guard self.isCurrent(generation: generation, configuration: configuration) else { return }
        self.loadReason = .inspectorDetail
    }

    private func publish(
        _ snapshot: CodexLocalProjectUsageSnapshot,
        generation: Int,
        configuration: Configuration)
    {
        guard self.isCurrent(generation: generation, configuration: configuration) else { return }
        guard Self.hasInspectorDetail(snapshot) else {
            self.failLoading(generation: generation, configuration: configuration)
            return
        }
        self.snapshot = snapshot
        self.hasLoadFailure = false
        self.reconcileSelectionState()
        self.finishLoading(generation: generation, configuration: configuration)
    }

    private func failLoading(generation: Int, configuration: Configuration) {
        guard self.isCurrent(generation: generation, configuration: configuration) else { return }
        guard !Task.isCancelled else {
            self.finishLoading(generation: generation, configuration: configuration)
            return
        }
        // Deliberately retain only an outcome bit. Error text may contain local
        // paths or account-derived details and is not required to recover.
        self.hasLoadFailure = true
        self.finishLoading(generation: generation, configuration: configuration)
    }

    private func finishLoading(generation: Int, configuration: Configuration) {
        guard self.isCurrent(generation: generation, configuration: configuration) else { return }
        self.loadTask = nil
        self.isLoading = false
        self.loadReason = nil
        self.progress = nil
    }

    private func isCurrent(generation: Int, configuration: Configuration) -> Bool {
        generation == self.requestGeneration && configuration == self.configuration
    }

    private static func hasInspectorDetail(_ snapshot: CodexLocalProjectUsageSnapshot) -> Bool {
        guard snapshot.hasInspectorDetail else { return false }
        return snapshot.total.totalTokens == 0 || !snapshot.projects.isEmpty
    }

    private func reconcileSelectionState(rankedProjectIDs: [String]? = nil) {
        guard let snapshot else { return }
        let projectIDs = self.projectIDs(in: snapshot, rankedProjectIDs: rankedProjectIDs)
        guard !projectIDs.isEmpty else {
            self.selectedProjectID = nil
            self.selectedSessionID = nil
            return
        }

        if !projectIDs.contains(self.selectedProjectID ?? "") {
            self.selectedProjectID = projectIDs.first
        }

        let sessionIDs = self.sessions(in: snapshot)
            .filter { $0.projectId == self.selectedProjectID }
            .map(\.id)
        if !sessionIDs.contains(self.selectedSessionID ?? "") {
            self.selectedSessionID = nil
        }
    }

    private func projectIDs(
        in snapshot: CodexLocalProjectUsageSnapshot,
        rankedProjectIDs: [String]? = nil) -> [String]
    {
        let availableIDs = Set(snapshot.projects.map(\.id))
        var seenIDs = Set<String>()
        let rankedIDs = (rankedProjectIDs ?? self.projectIDRanker(snapshot)).filter {
            availableIDs.contains($0) && seenIDs.insert($0).inserted
        }
        return rankedIDs + snapshot.projects.map(\.id).filter { seenIDs.insert($0).inserted }
    }

    private func sessions(in snapshot: CodexLocalProjectUsageSnapshot) -> [CodexLocalSessionUsage] {
        let indexedProjectIDs = Set(snapshot.sessions.map(\.projectId))
        let fallbackSessions = snapshot.projects
            .filter { !indexedProjectIDs.contains($0.id) }
            .flatMap(\.topSessions)
        return snapshot.sessions + fallbackSessions
    }
}
