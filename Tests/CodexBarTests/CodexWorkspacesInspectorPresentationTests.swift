import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CodexWorkspacesInspectorPresentationTests {
    private let visibleProjection = CodexLocalProjectUsageProjection(
        includesCachedInput: false,
        showsEstimatedCost: true)

    @Test
    func `presentation applies its fixed projection to ranked project rows`() {
        let snapshot = self.snapshot(
            projects: [
                self.project(id: "alpha", name: "Alpha", totalTokens: 300, cachedTokens: 100, cost: 2),
                self.project(id: "beta", name: "Beta", totalTokens: 250, cachedTokens: 0, cost: 1),
            ])

        let presentation = CodexWorkspacesInspectorPresentation(
            snapshot: snapshot,
            selectedProjectID: nil,
            projection: self.visibleProjection)

        #expect(presentation.rankedProjects.map(\.id) == ["beta", "alpha"])
        #expect(presentation.rankedProjects.map(\.tokens) == [250, 200])
        #expect(presentation.selectedProjectID == "beta")
        #expect(presentation.displayedTokens == 250)
    }

    @Test
    func `primary content state keeps a snapshot visible during refresh and distinguishes terminal states`() {
        let populated = self.snapshot(projects: [self.project(id: "project", name: "Project", totalTokens: 1)])
        let partial = self.snapshot(
            projects: [self.project(id: "project", name: "Project", totalTokens: 1)],
            sourceStatus: .catalogLocked)

        #expect(CodexWorkspacePrimaryContentState.resolve(
            snapshot: populated,
            isRefreshing: true,
            didFailInitialLoad: false) == .content(populated))
        #expect(CodexWorkspacePrimaryContentState.resolve(
            snapshot: partial,
            isRefreshing: false,
            didFailInitialLoad: false) == .partial(partial))
        #expect(CodexWorkspacePrimaryContentState.resolve(
            snapshot: partial,
            isRefreshing: false,
            didFailInitialLoad: true) == .partial(partial))
        #expect(CodexWorkspacePrimaryContentState.resolve(
            snapshot: nil,
            isRefreshing: true,
            didFailInitialLoad: false) == .loading)
        #expect(CodexWorkspacePrimaryContentState.resolve(
            snapshot: nil,
            isRefreshing: false,
            didFailInitialLoad: true) == .initialFailure)
        #expect(CodexWorkspacePrimaryContentState.resolve(
            snapshot: self.snapshot(),
            isRefreshing: false,
            didFailInitialLoad: false) == .completeEmpty)
    }

    @Test
    func `session filtering trims surrounding whitespace preserves model filtering and does not mutate rows`() {
        let rows = [
            self.sessionRow(id: "alpha", title: "Alpha chat", path: "/safe/alpha", model: "gpt-4.1", tokens: 100),
            self.sessionRow(id: "beta", title: "Beta chat", path: "/safe/beta", model: "o3", tokens: 300),
            self.sessionRow(id: "gamma", title: "Gamma chat", path: "/safe/gamma", model: "gpt-4.1", tokens: 200),
        ]
        let sort = [KeyPathComparator(\CodexWorkspacesSessionRow.tokenSortValue, order: .reverse)]

        let filtered = CodexWorkspaceSessionRows.filteredAndSorted(
            rows,
            searchText: "  Gamma chat ",
            selectedModel: "gpt-4.1",
            sortOrder: sort)

        #expect(filtered.map(\.id) == ["gamma"])
        #expect(rows.map(\.id) == ["alpha", "beta", "gamma"])
        #expect(CodexWorkspaceSessionRows.reconciledSelection("missing", availableModels: ["o3"]).isEmpty)
    }

    @Test
    func `selected project scopes sessions and keeps scalar top model`() {
        let alpha = self.project(id: "alpha", name: "Alpha", totalTokens: 500, topModel: "gpt-4.1")
        let beta = self.project(id: "beta", name: "Beta", totalTokens: 200, topModel: "o3")
        let snapshot = self.snapshot(
            projects: [alpha, beta],
            sessions: [
                self.session(id: "alpha-session", projectID: "alpha", title: "Alpha", tokens: 100),
                self.session(id: "beta-session", projectID: "beta", title: "Beta", tokens: 200),
            ])

        let presentation = CodexWorkspacesInspectorPresentation(
            snapshot: snapshot,
            selectedProjectID: "beta",
            projection: self.visibleProjection)

        #expect(presentation.selectedProjectID == "beta")
        #expect(presentation.sessions.map(\.id) == ["beta-session"])
        #expect(presentation.topModel == "o3")
    }

    @Test
    func `presentation uses project top sessions when detailed cache omits flat sessions`() {
        let topSession = self.session(
            id: "top-session",
            projectID: "project",
            title: "Cached detail",
            tokens: 100,
            daily: [self.dailyPoint])
        let project = self.project(
            id: "project",
            name: "Project",
            totalTokens: 100,
            topSessions: [topSession],
            daily: [self.dailyPoint])
        let snapshot = self.snapshot(projects: [project])

        #expect(snapshot.hasInspectorDetail)

        let presentation = CodexWorkspacesInspectorPresentation(
            snapshot: snapshot,
            selectedProjectID: "project",
            projection: self.visibleProjection)

        #expect(presentation.sessions.map(\.id) == ["top-session"])
    }

    @Test
    func `session row preserves unknown token totals`() {
        let row = CodexWorkspacesSessionRow(
            session: CodexLocalSessionUsage(
                id: "unknown",
                projectId: "project",
                displayTitle: "Unknown usage",
                cwd: nil,
                startedAt: nil,
                latestActivity: nil,
                totals: .unknown,
                costEstimate: CodexLocalCostEstimate(unknownTokens: 1),
                topModel: nil),
            projection: self.visibleProjection)

        #expect(row.tokens == nil)
        #expect(row.tokenSortValue < 0)
    }

    @Test
    func `cost state preserves known partial unavailable and hidden coverage`() {
        #expect(CodexWorkspacesCost(
            estimate: CodexLocalCostEstimate(knownUSD: 0, unknownTokens: 0)) == .known(0))
        #expect(CodexWorkspacesCost(
            estimate: CodexLocalCostEstimate(knownUSD: 4.5, unknownTokens: 3)) == .partial(knownUSD: 4.5))
        #expect(CodexWorkspacesCost(
            estimate: CodexLocalCostEstimate(knownUSD: 0, unknownTokens: 3)) == .unavailable)
        #expect(CodexWorkspacesCost(estimate: nil) == .hidden)
    }

    @Test
    func `project accessibility excludes private paths and keeps unavailable cost distinct from zero`() {
        let row = CodexWorkspacesProjectRow(
            project: self.project(
                id: "project",
                name: "Visible project",
                path: "/Users/person/Private Workspace",
                totalTokens: 42,
                costEstimate: CodexLocalCostEstimate(knownUSD: 0, unknownTokens: 42)),
            projection: CodexLocalProjectUsageProjection(
                includesCachedInput: true,
                showsEstimatedCost: true))

        #expect(!row.accessibilityDescription.contains("/Users/person/Private Workspace"))
        #expect(row.accessibilityDescription.contains(L("codex_workspaces_cost_unavailable")))
        #expect(!row.accessibilityDescription.contains(UsageFormatter.currencyString(0, currencyCode: "USD")))
        #expect(row.accessibilityDescription.contains("Visible project"))
    }

    private func snapshot(
        projects: [CodexLocalProjectUsage] = [],
        sessions: [CodexLocalSessionUsage] = [],
        sourceStatus: CodexLocalProjectUsageSourceStatus = .complete) -> CodexLocalProjectUsageSnapshot
    {
        CodexLocalProjectUsageSnapshot(
            updatedAt: Date(timeIntervalSinceReferenceDate: 0),
            historyDays: 30,
            scopeSignature: "scope",
            rootsFingerprint: [:],
            indexedFileCount: 0,
            skippedFileCount: 0,
            total: .empty,
            projects: projects,
            sessions: sessions,
            daily: [],
            sourceStatus: sourceStatus)
    }

    private func project(
        id: String,
        name: String,
        path: String? = nil,
        totalTokens: Int,
        cachedTokens: Int = 0,
        cost: Double = 0,
        costEstimate: CodexLocalCostEstimate? = nil,
        topModel: String? = nil,
        topSessions: [CodexLocalSessionUsage] = [],
        daily: [CodexLocalUsageDailyPoint] = []) -> CodexLocalProjectUsage
    {
        CodexLocalProjectUsage(
            id: id,
            displayName: name,
            path: path,
            totals: CodexLocalUsageTotals(
                inputTokens: totalTokens,
                cachedInputTokens: cachedTokens,
                outputTokens: 0,
                totalTokens: totalTokens),
            costEstimate: costEstimate ?? CodexLocalCostEstimate(knownUSD: cost),
            sessionCount: 0,
            latestActivity: nil,
            topModel: topModel,
            topSessions: topSessions,
            modelBreakdowns: [],
            daily: daily)
    }

    private func session(
        id: String,
        projectID: String,
        title: String,
        tokens: Int,
        model: String? = nil,
        daily: [CodexLocalUsageDailyPoint] = []) -> CodexLocalSessionUsage
    {
        CodexLocalSessionUsage(
            id: id,
            projectId: projectID,
            displayTitle: title,
            cwd: "/private/\(id)",
            startedAt: nil,
            latestActivity: nil,
            totals: CodexLocalUsageTotals(
                inputTokens: tokens,
                cachedInputTokens: 0,
                outputTokens: 0,
                totalTokens: tokens),
            costEstimate: CodexLocalCostEstimate(),
            topModel: model,
            daily: daily)
    }

    private func sessionRow(
        id: String,
        title: String,
        path: String,
        model: String,
        tokens: Int) -> CodexWorkspacesSessionRow
    {
        CodexWorkspacesSessionRow(
            session: CodexLocalSessionUsage(
                id: id,
                projectId: "project",
                displayTitle: title,
                cwd: path,
                startedAt: nil,
                latestActivity: nil,
                totals: CodexLocalUsageTotals(
                    inputTokens: tokens,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    totalTokens: tokens),
                costEstimate: CodexLocalCostEstimate(),
                topModel: model),
            projection: self.visibleProjection)
    }

    private var dailyPoint: CodexLocalUsageDailyPoint {
        CodexLocalUsageDailyPoint(
            day: "2026-08-30",
            totalTokens: 100,
            estimatedCostUSD: 1)
    }
}
