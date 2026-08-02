import CodexBarCore
import Foundation

enum CodexLocalProjectUsageWindowDestination {
    static let allWorkspacesID = "__codex_all_workspaces__"
}

enum CodexWorkspacePrimaryContentState {
    case content(CodexLocalProjectUsageSnapshot)
    case indexing
    case empty

    static func resolve(
        snapshot: CodexLocalProjectUsageSnapshot?,
        isRefreshing: Bool) -> Self
    {
        if let snapshot {
            return .content(snapshot)
        }
        return isRefreshing ? .indexing : .empty
    }
}

enum CodexWorkspaceSessionModelFilter {
    static func reconciledSelection(_ selectedModel: String, availableModels: [String]) -> String {
        selectedModel.isEmpty || availableModels.contains(selectedModel) ? selectedModel : ""
    }
}

enum CodexWorkspaceAssociatedSessionFilter {
    static func reconciledSessionIDs(
        _ sessionIDs: Set<String>?,
        from previousProjectID: String?,
        to selectedProjectID: String?) -> Set<String>?
    {
        previousProjectID == selectedProjectID ? sessionIDs : nil
    }
}

enum CodexWorkspaceSessionRows {
    static func filteredAndSorted(
        _ rows: [WorkspaceSessionRow],
        searchText: String,
        selectedModel: String,
        sortOrder: [KeyPathComparator<WorkspaceSessionRow>]) -> [WorkspaceSessionRow]
    {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            let matchesModel = selectedModel.isEmpty || row.model == selectedModel
            let matchesSearch = query.isEmpty
                || row.title.localizedCaseInsensitiveContains(query)
                || row.path.localizedCaseInsensitiveContains(query)
                || row.model.localizedCaseInsensitiveContains(query)
            return matchesModel && matchesSearch
        }
        .sorted(using: sortOrder)
    }
}

enum WorkspaceDailyUsageSelectionDirection {
    case earlier
    case later
}

enum WorkspaceDailyUsageSelectionNavigator {
    static func movingDate(
        from currentDate: Date?,
        direction: WorkspaceDailyUsageSelectionDirection,
        availableDates: [Date]) -> Date?
    {
        guard !availableDates.isEmpty else { return nil }
        guard let currentDate else {
            switch direction {
            case .earlier:
                return availableDates[max(availableDates.count - 2, 0)]
            case .later:
                return availableDates[availableDates.count - 1]
            }
        }

        let currentIndex = Self.closestIndex(to: currentDate, in: availableDates)
        let offset = switch direction {
        case .earlier: -1
        case .later: 1
        }
        let destinationIndex = min(max(currentIndex + offset, 0), availableDates.count - 1)
        return availableDates[destinationIndex]
    }

    private static func closestIndex(to date: Date, in dates: [Date]) -> Int {
        var lowerBound = 0
        var upperBound = dates.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if dates[midpoint] < date {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        guard lowerBound > 0 else { return 0 }
        guard lowerBound < dates.count else { return dates.count - 1 }
        let previousIndex = lowerBound - 1
        return abs(dates[previousIndex].timeIntervalSince(date)) <= abs(dates[lowerBound].timeIntervalSince(date))
            ? previousIndex
            : lowerBound
    }
}

enum CodexWorkspaceProjectAccessibilityDescription {
    static func make(
        projectName: String,
        tokenText: String,
        severity: CodexLocalUsageSeverity,
        estimatedCostText: String?,
        session: (count: Int, model: String?)) -> String
    {
        var components = [
            projectName,
            L("codex_workspaces_token_count_accessibility", tokenText),
            severity.workspaceAccessibilityDescription,
        ]
        if let estimatedCostText, !estimatedCostText.isEmpty {
            components.append(estimatedCostText)
        }
        components.append(L("codex_workspaces_session_count", session.count))
        if let model = session.model, !model.isEmpty {
            components.append(model)
        }
        return components.joined(separator: ", ")
    }
}

extension CodexLocalUsageSeverity {
    var workspaceAccessibilityDescription: String {
        switch self {
        case .normal:
            L("codex_workspaces_normal_usage")
        case .elevated:
            L("codex_workspaces_elevated_usage")
        case .high:
            L("codex_workspaces_high_usage")
        }
    }
}

struct CodexLocalProjectUsageWindowPresentation: Equatable {
    let snapshot: CodexLocalProjectUsageSnapshot
    let projection: CodexLocalProjectUsageProjection
    let rankedProjects: [CodexLocalProjectUsage]
    let selectedProject: CodexLocalProjectUsage?
    let selectedDestinationID: String
    let allWorkspaceTokens: Int?
    let displayedTokens: Int?
    let costEstimate: CodexLocalCostEstimate
    let sessions: [WorkspaceSessionRow]
    let models: [WorkspaceModelRow]
    let daily: [WorkspaceDailyPoint]
    let consistency: WorkspaceUsageConsistency
    let projectSessionCounts: [String: Int]
    let displayedProjectTokens: [String: Int]

    var isAllWorkspaces: Bool {
        self.selectedProject == nil
    }

    var sessionCount: Int {
        self.sessions.count
    }

    var topModel: String? {
        self.models.first?.model
    }

    init(
        snapshot: CodexLocalProjectUsageSnapshot,
        selectedDestinationID: String?,
        projection: CodexLocalProjectUsageProjection)
    {
        self.snapshot = snapshot
        self.projection = projection
        self.rankedProjects = projection.rankedProjects(snapshot.projects)
        let requestedID = selectedDestinationID ?? CodexLocalProjectUsageWindowDestination.allWorkspacesID
        self.selectedProject = requestedID == CodexLocalProjectUsageWindowDestination.allWorkspacesID
            ? nil
            : self.rankedProjects.first(where: { $0.id == requestedID })
        self.selectedDestinationID = self.selectedProject?.id
            ?? CodexLocalProjectUsageWindowDestination.allWorkspacesID

        let sourceSessions = self.selectedProject.map { project in
            snapshot.sessions.filter { $0.projectId == project.id }
        } ?? snapshot.sessions
        self.sessions = sourceSessions.map {
            WorkspaceSessionRow(session: $0, projection: projection)
        }
        .sorted { $0.tokens > $1.tokens }

        let sourceModels = self.selectedProject?.modelBreakdowns ?? snapshot.modelBreakdowns
        let displayedModelTokens = sourceModels.map { projection.displayedTokens(for: $0.totals) ?? 0 }
        let modelTokenTotal = displayedModelTokens.reduce(0, +)
        self.models = zip(sourceModels, displayedModelTokens).map { model, tokens in
            WorkspaceModelRow(
                breakdown: model,
                tokens: tokens,
                totalTokens: modelTokenTotal)
        }
        .sorted { $0.tokens > $1.tokens }

        let sourceDaily = self.selectedProject?.daily ?? snapshot.daily
        let dailyBreakdowns = self.selectedProject == nil
            ? Self.projectBreakdownsByDay(projects: self.rankedProjects, projection: projection)
            : Self.sessionBreakdownsByDay(sessions: sourceSessions, projection: projection)
        self.daily = sourceDaily.map {
            WorkspaceDailyPoint(
                point: $0,
                tokens: projection.displayedTokens(
                    totalTokens: $0.totalTokens,
                    cachedInputTokens: $0.cachedInputTokens),
                breakdownRows: dailyBreakdowns[$0.day] ?? [])
        }

        let totals = self.selectedProject?.totals ?? snapshot.total
        self.allWorkspaceTokens = projection.displayedTokens(for: snapshot.total)
        self.displayedTokens = projection.displayedTokens(for: totals)
        self.costEstimate = self.selectedProject?.costEstimate
            ?? Self.aggregateCost(snapshot.projects)
        self.projectSessionCounts = Dictionary(grouping: snapshot.sessions, by: \CodexLocalSessionUsage.projectId)
            .mapValues { $0.count }
        self.displayedProjectTokens = Dictionary(uniqueKeysWithValues: self.rankedProjects.map { project in
            (project.id, projection.displayedTokens(for: project.totals) ?? 0)
        })
        self.consistency = WorkspaceUsageConsistency(
            expectedTokens: self.displayedTokens,
            dailyTokens: self.daily.reduce(0) { $0 + $1.tokens },
            modelTokens: self.models.reduce(0) { $0 + $1.tokens },
            expectedSessionCount: self.selectedProject?.sessionCount ?? snapshot.sessions.count,
            visibleSessionCount: self.sessions.count,
            hasDailyData: !sourceDaily.isEmpty,
            hasModelData: !sourceModels.isEmpty,
            dailyBreakdownMismatch: self.daily.contains(where: { !$0.breakdownIsComplete }))
    }

    private static func aggregateCost(_ projects: [CodexLocalProjectUsage]) -> CodexLocalCostEstimate {
        projects.reduce(into: CodexLocalCostEstimate()) { result, project in
            result = CodexLocalCostEstimate(
                knownUSD: result.knownUSD + project.costEstimate.knownUSD,
                unknownTokens: result.unknownTokens + project.costEstimate.unknownTokens)
        }
    }

    private static func projectBreakdownsByDay(
        projects: [CodexLocalProjectUsage],
        projection: CodexLocalProjectUsageProjection) -> [String: [WorkspaceDailyBreakdownRow]]
    {
        var result: [String: [WorkspaceDailyBreakdownRow]] = [:]
        for project in projects {
            for point in project.daily {
                let tokens = projection.displayedTokens(
                    totalTokens: point.totalTokens,
                    cachedInputTokens: point.cachedInputTokens)
                guard tokens > 0 else { continue }
                result[point.day, default: []].append(WorkspaceDailyBreakdownRow(
                    id: project.id,
                    kind: .project,
                    title: project.displayName,
                    tokens: tokens))
            }
        }
        return result.mapValues(Self.sortedBreakdownRows)
    }

    private static func sessionBreakdownsByDay(
        sessions: [CodexLocalSessionUsage],
        projection: CodexLocalProjectUsageProjection) -> [String: [WorkspaceDailyBreakdownRow]]
    {
        var result: [String: [WorkspaceDailyBreakdownRow]] = [:]
        for session in sessions {
            let title = session.displayTitle == CodexLocalSessionUsage.localChatFallbackTitle
                ? L("codex_workspaces_local_codex_chat")
                : session.displayTitle
            for point in session.daily {
                let tokens = projection.displayedTokens(
                    totalTokens: point.totalTokens,
                    cachedInputTokens: point.cachedInputTokens)
                guard tokens > 0 else { continue }
                result[point.day, default: []].append(WorkspaceDailyBreakdownRow(
                    id: session.id,
                    kind: .session,
                    title: title,
                    tokens: tokens))
            }
        }
        return result.mapValues(Self.sortedBreakdownRows)
    }

    private static func sortedBreakdownRows(
        _ rows: [WorkspaceDailyBreakdownRow]) -> [WorkspaceDailyBreakdownRow]
    {
        rows.sorted { lhs, rhs in
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

struct WorkspaceUsageConsistency: Equatable {
    let expectedTokens: Int?
    let dailyTokenDelta: Int?
    let modelTokenDelta: Int?
    let sessionCountDelta: Int
    let dailyUnavailable: Bool
    let modelsUnavailable: Bool
    let dailyBreakdownMismatch: Bool

    init(
        expectedTokens: Int?,
        dailyTokens: Int,
        modelTokens: Int,
        expectedSessionCount: Int,
        visibleSessionCount: Int,
        hasDailyData: Bool,
        hasModelData: Bool,
        dailyBreakdownMismatch: Bool)
    {
        self.expectedTokens = expectedTokens
        self.dailyTokenDelta = hasDailyData ? expectedTokens.map { dailyTokens - $0 } : nil
        self.modelTokenDelta = hasModelData ? expectedTokens.map { modelTokens - $0 } : nil
        self.sessionCountDelta = visibleSessionCount - expectedSessionCount
        self.dailyUnavailable = !hasDailyData && (expectedTokens ?? 0) > 0
        self.modelsUnavailable = !hasModelData && (expectedTokens ?? 0) > 0
        self.dailyBreakdownMismatch = dailyBreakdownMismatch
    }

    var hasMismatch: Bool {
        self.dailyTokenDelta.map { $0 != 0 } == true
            || self.modelTokenDelta.map { $0 != 0 } == true
            || self.sessionCountDelta != 0
            || self.dailyBreakdownMismatch
    }
}

struct WorkspaceSessionRow: Identifiable, Equatable {
    let id: String
    let title: String
    let path: String
    let startedAt: Date?
    let model: String
    let tokens: Int
    let costEstimate: CodexLocalCostEstimate

    init(session: CodexLocalSessionUsage, projection: CodexLocalProjectUsageProjection) {
        self.id = session.id
        self.title = session.displayTitle == CodexLocalSessionUsage.localChatFallbackTitle
            ? L("codex_workspaces_local_codex_chat")
            : session.displayTitle
        self.path = session.cwd ?? "—"
        self.startedAt = session.startedAt ?? session.latestActivity
        self.model = session.topModel ?? "—"
        self.tokens = projection.displayedTokens(for: session.totals) ?? 0
        self.costEstimate = session.costEstimate
    }

    var startedSortValue: Date {
        self.startedAt ?? .distantPast
    }

    var costSortValue: Double {
        self.costEstimate.knownUSD
    }

    var startedText: String {
        self.startedAt?.formatted(.dateTime.month(.abbreviated).day().hour().minute()) ?? "—"
    }

    var tokenText: String {
        UsageFormatter.tokenCountString(self.tokens)
    }
}

struct WorkspaceModelRow: Identifiable, Equatable {
    let id: String
    let model: String
    let tokens: Int
    let percentage: Double
    let costEstimate: CodexLocalCostEstimate

    init(breakdown: CodexLocalUsageModelBreakdown, tokens: Int, totalTokens: Int) {
        self.id = breakdown.id
        self.model = breakdown.model
        self.tokens = tokens
        self.percentage = totalTokens == 0 ? 0 : Double(tokens) / Double(totalTokens)
        self.costEstimate = breakdown.costEstimate
    }

    var costSortValue: Double {
        self.costEstimate.knownUSD
    }

    var tokenText: String {
        UsageFormatter.tokenCountString(self.tokens)
    }

    var percentText: String {
        self.percentage.formatted(.percent.precision(.fractionLength(1)))
    }
}

struct WorkspaceDailyPoint: Identifiable, Equatable {
    let id: String
    let day: String
    let date: Date
    let tokens: Int
    let estimatedCostUSD: Double?
    let breakdownRows: [WorkspaceDailyBreakdownRow]

    init(
        point: CodexLocalUsageDailyPoint,
        tokens: Int,
        breakdownRows: [WorkspaceDailyBreakdownRow] = [],
        calendar: Calendar = .current)
    {
        self.id = point.id
        self.day = point.day
        self.date = Self.dateFromDayKey(point.day, calendar: calendar)
        self.tokens = tokens
        self.estimatedCostUSD = point.estimatedCostUSD
        self.breakdownRows = breakdownRows
    }

    var breakdownIsComplete: Bool {
        self.breakdownRows.reduce(0) { $0 + $1.tokens } == self.tokens
    }

    static func dateFromDayKey(_ day: String, calendar: Calendar = .current) -> Date {
        let values = day.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return .distantPast }
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = calendar.timeZone
        var components = DateComponents()
        components.calendar = localCalendar
        components.timeZone = localCalendar.timeZone
        components.year = values[0]
        components.month = values[1]
        components.day = values[2]
        return components.date ?? .distantPast
    }
}

struct WorkspaceDailyBreakdownRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case project
        case session
    }

    let id: String
    let kind: Kind
    let title: String
    let tokens: Int

    var tokenText: String {
        UsageFormatter.tokenCountString(self.tokens)
    }
}
