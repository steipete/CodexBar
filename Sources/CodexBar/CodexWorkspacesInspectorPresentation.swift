import CodexBarCore
import Foundation

enum CodexWorkspacePrimaryContentState: Equatable {
    case loading
    case content(CodexLocalProjectUsageSnapshot)
    case completeEmpty
    case partial(CodexLocalProjectUsageSnapshot)
    case initialFailure

    static func resolve(
        snapshot: CodexLocalProjectUsageSnapshot?,
        isRefreshing: Bool,
        didFailInitialLoad: Bool) -> Self
    {
        guard let snapshot else {
            if isRefreshing {
                return .loading
            }
            return didFailInitialLoad ? .initialFailure : .completeEmpty
        }

        if snapshot.sourceStatus.isPartial {
            return .partial(snapshot)
        }
        if snapshot.projects.isEmpty, snapshot.sessions.isEmpty {
            return .completeEmpty
        }
        return .content(snapshot)
    }
}

enum CodexWorkspacesCost: Equatable {
    case hidden
    case known(Double)
    case partial(knownUSD: Double)
    case unavailable

    init(estimate: CodexLocalCostEstimate?) {
        guard let estimate else {
            self = .hidden
            return
        }

        switch estimate.coverage {
        case .known:
            self = .known(estimate.knownUSD)
        case .partial:
            self = .partial(knownUSD: estimate.knownUSD)
        case .unavailable:
            self = .unavailable
        }
    }
}

struct CodexWorkspacesProjectRow: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String?
    let tokens: Int?
    let cost: CodexWorkspacesCost
    let severity: CodexLocalUsageSeverity
    let sessionCount: Int
    let latestActivity: Date?

    var accessibilityDescription: String {
        CodexWorkspaceProjectAccessibilityDescription.make(
            projectName: self.name,
            tokens: self.tokens,
            severity: self.severity,
            cost: self.cost,
            sessionCount: self.sessionCount)
    }

    init(project: CodexLocalProjectUsage, projection: CodexLocalProjectUsageProjection) {
        self.id = project.id
        self.name = project.displayName
        self.path = project.path
        self.tokens = projection.displayedTokens(for: project.totals)
        self.cost = CodexWorkspacesCost(estimate: projection.displayedCost(for: project.costEstimate))
        self.severity = project.severity
        self.sessionCount = project.sessionCount
        self.latestActivity = project.latestActivity
    }
}

struct CodexWorkspacesSessionRow: Identifiable, Equatable {
    let id: String
    let title: String
    let searchablePath: String
    let startedAt: Date?
    let model: String
    let tokens: Int?
    let cost: CodexWorkspacesCost

    var startedSortValue: Date {
        self.startedAt ?? .distantPast
    }

    var costSortValue: Double? {
        switch self.cost {
        case let .known(value), let .partial(value):
            value
        case .hidden, .unavailable:
            nil
        }
    }

    var tokenSortValue: Int {
        self.tokens ?? -1
    }

    init(session: CodexLocalSessionUsage, projection: CodexLocalProjectUsageProjection) {
        self.id = session.id
        self.title = session.displayTitle == CodexLocalSessionUsage.localChatFallbackTitle
            ? L("codex_workspaces_local_codex_chat")
            : session.displayTitle
        self.searchablePath = session.cwd ?? ""
        self.startedAt = session.startedAt ?? session.latestActivity
        self.model = session.topModel ?? ""
        self.tokens = projection.displayedTokens(for: session.totals)
        self.cost = CodexWorkspacesCost(estimate: projection.displayedCost(for: session.costEstimate))
    }
}

enum CodexWorkspaceSessionRows {
    static func reconciledSelection(_ selectedModel: String, availableModels: [String]) -> String {
        selectedModel.isEmpty || availableModels.contains(selectedModel) ? selectedModel : ""
    }

    static func filteredAndSorted(
        _ rows: [CodexWorkspacesSessionRow],
        searchText: String,
        selectedModel: String,
        sortOrder: [KeyPathComparator<CodexWorkspacesSessionRow>]) -> [CodexWorkspacesSessionRow]
    {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            let matchesModel = selectedModel.isEmpty || row.model == selectedModel
            guard matchesModel else { return false }
            guard !query.isEmpty else { return true }
            return row.title.localizedCaseInsensitiveContains(query)
                || row.searchablePath.localizedCaseInsensitiveContains(query)
                || row.model.localizedCaseInsensitiveContains(query)
        }
        .sorted(using: sortOrder)
    }
}

struct CodexWorkspacesInspectorPresentation: Equatable {
    static let projection = CodexLocalProjectUsageProjection(
        includesCachedInput: true,
        showsEstimatedCost: true)

    let snapshot: CodexLocalProjectUsageSnapshot
    let selectedProjectID: String?
    let selectedProject: CodexLocalProjectUsage?
    let rankedProjects: [CodexWorkspacesProjectRow]
    let sessions: [CodexWorkspacesSessionRow]
    let displayedTokens: Int?
    let cost: CodexWorkspacesCost
    let topModel: String?

    init(
        snapshot: CodexLocalProjectUsageSnapshot,
        selectedProjectID: String?,
        projection: CodexLocalProjectUsageProjection)
    {
        self.snapshot = snapshot
        let rankedProjects = projection.rankedProjects(snapshot.projects)
        let selectedProject = selectedProjectID.flatMap { requestedID in
            rankedProjects.first(where: { $0.id == requestedID })
        } ?? rankedProjects.first
        self.selectedProject = selectedProject
        self.selectedProjectID = selectedProject?.id
        self.rankedProjects = rankedProjects.map { project in
            CodexWorkspacesProjectRow(project: project, projection: projection)
        }

        let sourceSessions: [CodexLocalSessionUsage] = selectedProject.map { project in
            let indexedSessions = snapshot.sessions.filter { $0.projectId == project.id }
            return indexedSessions.isEmpty ? project.topSessions : indexedSessions
        } ?? []
        self.sessions = sourceSessions.map {
            CodexWorkspacesSessionRow(session: $0, projection: projection)
        }
        .sorted(by: Self.sessionOrder)

        self.displayedTokens = selectedProject.flatMap { projection.displayedTokens(for: $0.totals) }
        self.cost = CodexWorkspacesCost(
            estimate: selectedProject.flatMap { projection.displayedCost(for: $0.costEstimate) })
        self.topModel = selectedProject?.topModel
    }

    private static func sessionOrder(_ lhs: CodexWorkspacesSessionRow, _ rhs: CodexWorkspacesSessionRow) -> Bool {
        switch (lhs.tokens, rhs.tokens) {
        case let (lhsTokens?, rhsTokens?) where lhsTokens != rhsTokens:
            return lhsTokens > rhsTokens
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id < rhs.id
    }
}

enum CodexWorkspaceProjectAccessibilityDescription {
    static func make(
        projectName: String,
        tokens: Int?,
        severity: CodexLocalUsageSeverity,
        cost: CodexWorkspacesCost,
        sessionCount: Int) -> String
    {
        var components = [projectName]
        if let tokens {
            components.append(L(
                "codex_workspaces_token_count_accessibility",
                UsageFormatter.tokenCountString(tokens)))
        }
        components.append(Self.severityDescription(severity))
        if let costDescription = Self.costDescription(cost) {
            components.append(costDescription)
        }
        components.append(L("codex_workspaces_session_count", sessionCount))
        return components.joined(separator: ", ")
    }

    private static func severityDescription(_ severity: CodexLocalUsageSeverity) -> String {
        switch severity {
        case .normal:
            L("codex_workspaces_normal_usage")
        case .elevated:
            L("codex_workspaces_elevated_usage")
        case .high:
            L("codex_workspaces_high_usage")
        }
    }

    private static func costDescription(_ cost: CodexWorkspacesCost) -> String? {
        switch cost {
        case .hidden:
            nil
        case .unavailable:
            L("codex_workspaces_cost_unavailable")
        case let .known(value):
            L(
                "codex_workspaces_estimated_cost_value",
                UsageFormatter.currencyString(value, currencyCode: "USD"))
        case let .partial(knownUSD):
            [
                L("codex_workspaces_partial_data"),
                L(
                    "codex_workspaces_estimated_cost_value",
                    UsageFormatter.currencyString(knownUSD, currencyCode: "USD")),
            ].joined(separator: ", ")
        }
    }
}
