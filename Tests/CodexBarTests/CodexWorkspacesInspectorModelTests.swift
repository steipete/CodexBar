import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct CodexWorkspacesInspectorModelTests {
    @Test
    func `detailed cache publishes without a normal load`() async {
        let cacheSnapshot = Self.snapshot(marker: 1, projects: [Self.project(id: "project-a")])
        let loader = ImmediateLoader(cached: cacheSnapshot, normal: [.snapshot(Self.snapshot(marker: 2))])
        let model = self.model(loader: loader)

        model.load()
        await model.waitForCurrentLoad()

        #expect(model.snapshot?.indexedFileCount == 1)
        #expect(!model.isLoading)
        #expect(await loader.normalForceRefreshes() == [])
    }

    @Test
    func `missing and aggregate cache each perform one non-forced normal load`() async {
        let refreshed = Self.snapshot(marker: 2, projects: [Self.project(id: "project-a")])
        let missing = ImmediateLoader(cached: nil, normal: [.snapshot(refreshed)])
        let missingModel = self.model(loader: missing)

        missingModel.load()
        await missingModel.waitForCurrentLoad()

        #expect(missingModel.snapshot?.indexedFileCount == 2)
        #expect(await missing.normalForceRefreshes() == [false])

        let aggregate = Self.snapshot(marker: 1, projects: [])
        let aggregateOnly = ImmediateLoader(cached: aggregate, normal: [.snapshot(refreshed)])
        let aggregateModel = self.model(loader: aggregateOnly)

        aggregateModel.load()
        await aggregateModel.waitForCurrentLoad()

        #expect(aggregateModel.snapshot?.indexedFileCount == 2)
        #expect(await aggregateOnly.normalForceRefreshes() == [false])
    }

    @Test
    func `aggregate-only normal result is a recoverable failure rather than an empty inspector`() async {
        let aggregate = Self.snapshot(marker: 1, projects: [])
        let loader = ImmediateLoader(cached: nil, normal: [.snapshot(aggregate)])
        let model = self.model(loader: loader)

        model.load()
        await model.waitForCurrentLoad()

        #expect(model.snapshot == nil)
        #expect(model.hasLoadFailure)
        #expect(!model.isLoading)
        #expect(await loader.normalForceRefreshes() == [false])
    }

    @Test
    func `explicit refresh is forced and failure retains last good content without error text`() async {
        let cached = Self.snapshot(marker: 1, projects: [Self.project(id: "project-a")])
        let loader = ImmediateLoader(cached: cached, normal: [.failure])
        let model = self.model(loader: loader)

        model.load()
        await model.waitForCurrentLoad()
        model.refresh()
        await model.waitForCurrentLoad()

        #expect(await loader.normalForceRefreshes() == [true])
        #expect(model.snapshot?.indexedFileCount == 1)
        #expect(model.hasLoadFailure)
        #expect(!model.isLoading)
    }

    @Test
    func `refresh failure preserves partial content without promoting it to complete`() async {
        let partial = Self.snapshot(
            marker: 1,
            projects: [Self.project(id: "project-a")],
            sourceStatus: .catalogLocked)
        let loader = ImmediateLoader(cached: partial, normal: [.failure])
        let model = self.model(loader: loader)

        model.load()
        await model.waitForCurrentLoad()

        #expect(model.snapshot?.sourceStatus == .catalogLocked)
        #expect(CodexWorkspacePrimaryContentState.resolve(
            snapshot: model.snapshot,
            isRefreshing: model.isLoading,
            didFailInitialLoad: model.hasLoadFailure) == .partial(partial))

        model.refresh()
        await model.waitForCurrentLoad()

        #expect(await loader.normalForceRefreshes() == [true])
        #expect(model.snapshot?.sourceStatus == .catalogLocked)
        #expect(model.hasLoadFailure)
        #expect(!model.isLoading)
        #expect(CodexWorkspacePrimaryContentState.resolve(
            snapshot: model.snapshot,
            isRefreshing: model.isLoading,
            didFailInitialLoad: model.hasLoadFailure) == .partial(partial))
    }

    @Test
    func `cancelling a refresh preserves last good content`() async {
        let cached = Self.snapshot(marker: 1, projects: [Self.project(id: "project-a")])
        let gate = BlockingLoader()
        let model = self.model(
            cachedLoader: { _ in cached },
            snapshotLoader: { configuration, forceRefresh, progress in
                try await gate.load(configuration: configuration, forceRefresh: forceRefresh, progress: progress)
            })

        model.load()
        await model.waitForCurrentLoad()
        model.refresh()
        await self.wait(forNormalLoads: 1, from: gate)
        model.cancelLoading()
        await gate.resumeNext(with: Self.snapshot(marker: 2, projects: [Self.project(id: "new")]))
        for _ in 0..<8 {
            await Task.yield()
        }

        #expect(model.snapshot?.indexedFileCount == 1)
        #expect(!model.hasLoadFailure)
        #expect(!model.isLoading)
    }

    @Test
    func `duplicate load shares one request and cancelled stale load cannot overwrite refresh`() async {
        let gate = BlockingLoader()
        let model = self.model(
            cachedLoader: { _ in nil },
            snapshotLoader: { configuration, forceRefresh, progress in
                try await gate.load(configuration: configuration, forceRefresh: forceRefresh, progress: progress)
            })

        model.load()
        model.load()
        await self.wait(forNormalLoads: 1, from: gate)
        model.refresh()
        #expect(await gate.forceRefreshes() == [false])

        await gate.resumeNext(with: Self.snapshot(marker: 1, projects: [Self.project(id: "current")]))
        await model.waitForCurrentLoad()

        #expect(await gate.forceRefreshes() == [false])
        #expect(model.snapshot?.indexedFileCount == 1)
        #expect(model.progress == nil)
        #expect(!model.isLoading)
    }

    @Test
    func `reopening valid content and repeated refresh do not start equivalent work`() async {
        let cached = Self.snapshot(marker: 1, projects: [Self.project(id: "project-a")])
        let gate = BlockingLoader()
        let model = self.model(
            cachedLoader: { _ in cached },
            snapshotLoader: { configuration, forceRefresh, progress in
                try await gate.load(configuration: configuration, forceRefresh: forceRefresh, progress: progress)
            })

        model.load()
        await model.waitForCurrentLoad()
        model.load()
        #expect(await gate.forceRefreshes() == [])

        model.refresh()
        model.refresh()
        await self.wait(forNormalLoads: 1, from: gate)
        #expect(await gate.forceRefreshes() == [true])
        await gate.resumeNext(with: Self.snapshot(marker: 2, projects: [Self.project(id: "project-a")]))
        await model.waitForCurrentLoad()
    }

    @Test
    func `configuration change clears privacy scope content and rejects stale publication`() async {
        let oldSnapshot = Self.snapshot(marker: 1, projects: [Self.project(id: "old")])
        let privateSnapshot = Self.snapshot(
            marker: 2,
            projects: [Self.project(id: "private")],
            scope: "private")
        let gate = BlockingLoader()
        let oldConfiguration = Self.configuration(scope: "old", hidePersonalInfo: false)
        let newConfiguration = Self.configuration(scope: "private", hidePersonalInfo: true)
        let model = CodexWorkspacesInspectorModel(
            configuration: oldConfiguration,
            cachedSnapshotLoader: { configuration in
                configuration.scopeSignature == "old" ? oldSnapshot : privateSnapshot
            },
            snapshotLoader: { configuration, forceRefresh, progress in
                try await gate.load(configuration: configuration, forceRefresh: forceRefresh, progress: progress)
            })

        model.load()
        await model.waitForCurrentLoad()
        #expect(model.snapshot?.indexedFileCount == 1)

        model.refresh()
        await self.wait(forNormalLoads: 1, from: gate)
        model.updateConfiguration(newConfiguration)
        #expect(model.snapshot == nil)
        #expect(model.selectedProjectID == nil)
        #expect(model.selectedSessionID == nil)
        #expect(!model.isLoading)

        model.load()
        await model.waitForCurrentLoad()
        #expect(model.snapshot?.indexedFileCount == 2)
        await gate.resumeNext(with: oldSnapshot)
        for _ in 0..<8 {
            await Task.yield()
        }

        #expect(model.snapshot?.indexedFileCount == 2)
        #expect(model.snapshot?.scopeSignature == "private")
    }

    @Test
    func `project and session selection reconciles to ranked surviving stable ids`() async {
        let initial = Self.snapshot(
            marker: 1,
            projects: [Self.project(id: "project-b"), Self.project(id: "project-a")],
            sessions: [
                Self.session(id: "session-b", projectID: "project-b"),
                Self.session(id: "session-a", projectID: "project-a"),
            ])
        let updated = Self.snapshot(
            marker: 2,
            projects: [Self.project(id: "project-a")],
            sessions: [Self.session(id: "session-a-new", projectID: "project-a")])
        let loader = ImmediateLoader(cached: initial, normal: [.snapshot(updated)])
        let model = self.model(loader: loader, ranker: { _ in ["project-a", "project-b"] })

        model.load()
        await model.waitForCurrentLoad()
        #expect(model.selectedProjectID == "project-a")
        #expect(model.selectedSessionID == nil)

        model.selectSession(id: "session-b")
        #expect(model.selectedProjectID == "project-a")
        #expect(model.selectedSessionID == nil)

        model.selectSession(id: "session-a")
        #expect(model.selectedSessionID == "session-a")

        model.selectProject(id: "project-b")
        #expect(model.selectedProjectID == "project-b")
        #expect(model.selectedSessionID == nil)

        model.refresh()
        await model.waitForCurrentLoad()
        #expect(model.selectedProjectID == "project-a")
        #expect(model.selectedSessionID == nil)
    }

    private func model(
        loader: ImmediateLoader,
        ranker: @escaping CodexWorkspacesInspectorModel.ProjectIDRanker = { snapshot in snapshot.projects.map(\.id) })
        -> CodexWorkspacesInspectorModel
    {
        self.model(
            cachedLoader: { configuration in await loader.cached(configuration) },
            snapshotLoader: { configuration, forceRefresh, progress in
                try await loader.load(configuration: configuration, forceRefresh: forceRefresh, progress: progress)
            },
            ranker: ranker)
    }

    private func model(
        cachedLoader: @escaping CodexWorkspacesInspectorModel.CachedSnapshotLoader,
        snapshotLoader: @escaping CodexWorkspacesInspectorModel.SnapshotLoader,
        ranker: @escaping CodexWorkspacesInspectorModel.ProjectIDRanker = { snapshot in snapshot.projects.map(\.id) })
        -> CodexWorkspacesInspectorModel
    {
        CodexWorkspacesInspectorModel(
            configuration: Self.configuration(scope: "scope", hidePersonalInfo: false),
            cachedSnapshotLoader: cachedLoader,
            snapshotLoader: snapshotLoader,
            projectIDRanker: ranker)
    }

    private func wait(forNormalLoads expected: Int, from loader: BlockingLoader) async {
        for _ in 0..<100 {
            if await loader.normalLoadCount() >= expected { return }
            await Task.yield()
        }
        #expect(await loader.normalLoadCount() >= expected)
    }

    private static func configuration(scope: String, hidePersonalInfo: Bool) -> CodexWorkspacesInspectorModel
    .Configuration {
        CodexWorkspacesInspectorModel.Configuration(
            codexHomePath: "/tmp/\(scope)",
            scopeSignature: scope,
            historyDays: 30,
            hidePersonalInfo: hidePersonalInfo)
    }

    private static func snapshot(
        marker: Int,
        projects: [CodexLocalProjectUsage] = [Self.project(id: "project-a")],
        sessions: [CodexLocalSessionUsage] = [],
        scope: String = "scope",
        sourceStatus: CodexLocalProjectUsageSourceStatus = .complete) -> CodexLocalProjectUsageSnapshot
    {
        CodexLocalProjectUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: TimeInterval(marker)),
            historyDays: 30,
            scopeSignature: scope,
            rootsFingerprint: [:],
            indexedFileCount: marker,
            skippedFileCount: 0,
            total: CodexLocalUsageTotals(
                inputTokens: marker,
                cachedInputTokens: 0,
                outputTokens: 0,
                totalTokens: marker),
            projects: projects,
            sessions: sessions,
            daily: [],
            sourceStatus: sourceStatus)
    }

    private static func project(id: String) -> CodexLocalProjectUsage {
        CodexLocalProjectUsage(
            id: id,
            displayName: id,
            path: "/tmp/\(id)",
            totals: CodexLocalUsageTotals(inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1),
            estimatedCostUSD: nil,
            hasUnknownCost: false,
            sessionCount: 0,
            latestActivity: nil,
            topModel: nil,
            topSessions: [],
            modelBreakdowns: [],
            daily: [CodexLocalUsageDailyPoint(
                day: "2026-08-30",
                totalTokens: 1,
                cachedInputTokens: 0,
                estimatedCostUSD: 0)])
    }

    private static func session(id: String, projectID: String) -> CodexLocalSessionUsage {
        CodexLocalSessionUsage(
            id: id,
            projectId: projectID,
            displayTitle: id,
            cwd: nil,
            startedAt: nil,
            latestActivity: nil,
            totals: CodexLocalUsageTotals(inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, totalTokens: 1),
            estimatedCostUSD: nil,
            hasUnknownCost: false,
            topModel: nil,
            daily: [CodexLocalUsageDailyPoint(
                day: "2026-08-30",
                totalTokens: 1,
                cachedInputTokens: 0,
                estimatedCostUSD: 0)])
    }
}

private actor ImmediateLoader {
    enum Outcome: Sendable {
        case snapshot(CodexLocalProjectUsageSnapshot)
        case failure
    }

    private let cachedSnapshot: CodexLocalProjectUsageSnapshot?
    private var normalOutcomes: [Outcome]
    private var recordedForceRefreshes: [Bool] = []

    init(cached: CodexLocalProjectUsageSnapshot?, normal: [Outcome]) {
        self.cachedSnapshot = cached
        self.normalOutcomes = normal
    }

    func cached(_: CodexWorkspacesInspectorModel.Configuration) -> CodexLocalProjectUsageSnapshot? {
        self.cachedSnapshot
    }

    func load(
        configuration _: CodexWorkspacesInspectorModel.Configuration,
        forceRefresh: Bool,
        progress: @escaping @Sendable (CodexLocalProjectUsageIndexProgress) -> Void) throws
        -> CodexLocalProjectUsageSnapshot
    {
        self.recordedForceRefreshes.append(forceRefresh)
        progress(CodexLocalProjectUsageIndexProgress(phase: .indexingProjects, indexedFileCount: 1))
        guard !self.normalOutcomes.isEmpty else { throw FixtureError.failed }
        switch self.normalOutcomes.removeFirst() {
        case let .snapshot(snapshot): return snapshot
        case .failure: throw FixtureError.failed
        }
    }

    func normalForceRefreshes() -> [Bool] {
        self.recordedForceRefreshes
    }
}

private actor BlockingLoader {
    private var forceRefreshRequests: [Bool] = []
    private var continuations: [CheckedContinuation<CodexLocalProjectUsageSnapshot, Never>] = []

    func load(
        configuration _: CodexWorkspacesInspectorModel.Configuration,
        forceRefresh: Bool,
        progress: @escaping @Sendable (CodexLocalProjectUsageIndexProgress) -> Void) async throws
        -> CodexLocalProjectUsageSnapshot
    {
        self.forceRefreshRequests.append(forceRefresh)
        progress(CodexLocalProjectUsageIndexProgress(phase: .scanningLogs, indexedFileCount: 1))
        return await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }

    func normalLoadCount() -> Int {
        self.forceRefreshRequests.count
    }

    func forceRefreshes() -> [Bool] {
        self.forceRefreshRequests
    }

    func resumeNext(with snapshot: CodexLocalProjectUsageSnapshot) {
        guard !self.continuations.isEmpty else { return }
        self.continuations.removeFirst().resume(returning: snapshot)
    }
}

private enum FixtureError: Error, Sendable {
    case failed
}
