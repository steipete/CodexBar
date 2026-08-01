import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CodexWorkspacePresentationInteractionTests {
    @Test
    func `session model filter clears only unavailable selections`() {
        #expect(CodexWorkspaceSessionModelFilter.reconciledSelection(
            "gpt-5",
            availableModels: ["gpt-5", "o3"]) == "gpt-5")
        #expect(CodexWorkspaceSessionModelFilter.reconciledSelection(
            "missing-model",
            availableModels: ["gpt-5", "o3"]).isEmpty)
        #expect(CodexWorkspaceSessionModelFilter.reconciledSelection(
            "missing-model",
            availableModels: []).isEmpty)
        #expect(CodexWorkspaceSessionModelFilter.reconciledSelection(
            "",
            availableModels: ["gpt-5"]).isEmpty)
    }

    @Test
    func `associated session filter clears when workspace selection changes`() {
        let sessionIDs: Set = ["session-one", "session-two"]

        #expect(CodexWorkspaceAssociatedSessionFilter.reconciledSessionIDs(
            sessionIDs,
            from: "workspace-one",
            to: "workspace-one") == sessionIDs)
        #expect(CodexWorkspaceAssociatedSessionFilter.reconciledSessionIDs(
            sessionIDs,
            from: "workspace-one",
            to: "workspace-two") == nil)
        #expect(CodexWorkspaceAssociatedSessionFilter.reconciledSessionIDs(
            sessionIDs,
            from: CodexLocalProjectUsageWindowDestination.allWorkspacesID,
            to: "workspace-one") == nil)
    }

    @Test
    func `sidebar selection navigation moves and clamps`() {
        let allWorkspacesID = CodexLocalProjectUsageWindowDestination.allWorkspacesID
        let orderedIDs = [allWorkspacesID, "workspace-one", "workspace-two"]

        #expect(CodexWorkspaceSidebarSelectionNavigator.movingSelection(
            from: allWorkspacesID,
            direction: .down,
            orderedIDs: orderedIDs) == "workspace-one")
        #expect(CodexWorkspaceSidebarSelectionNavigator.movingSelection(
            from: "workspace-one",
            direction: .up,
            orderedIDs: orderedIDs) == allWorkspacesID)
        #expect(CodexWorkspaceSidebarSelectionNavigator.movingSelection(
            from: allWorkspacesID,
            direction: .up,
            orderedIDs: orderedIDs) == allWorkspacesID)
        #expect(CodexWorkspaceSidebarSelectionNavigator.movingSelection(
            from: "workspace-two",
            direction: .down,
            orderedIDs: orderedIDs) == "workspace-two")
    }

    @Test
    func `sidebar selection navigation recovers invalid and empty selections`() {
        let allWorkspacesID = CodexLocalProjectUsageWindowDestination.allWorkspacesID
        let orderedIDs = [allWorkspacesID, "workspace-one"]

        #expect(CodexWorkspaceSidebarSelectionNavigator.movingSelection(
            from: nil,
            direction: .up,
            orderedIDs: orderedIDs) == allWorkspacesID)
        #expect(CodexWorkspaceSidebarSelectionNavigator.movingSelection(
            from: "missing-workspace",
            direction: .down,
            orderedIDs: orderedIDs) == allWorkspacesID)
        #expect(CodexWorkspaceSidebarSelectionNavigator.movingSelection(
            from: nil,
            direction: .down,
            orderedIDs: [allWorkspacesID]) == allWorkspacesID)
        #expect(CodexWorkspaceSidebarSelectionNavigator.movingSelection(
            from: allWorkspacesID,
            direction: .down,
            orderedIDs: []) == nil)
    }

    @Test
    func `models metric copy distinguishes known cost from complete totals`() {
        #expect(CodexModelsMetric.tokens.analyticsNoun == "tokens")
        #expect(CodexModelsMetric.tokens.shareBasisTitle == "total tokens")
        #expect(CodexModelsMetric.knownCost.analyticsNoun == "known cost")
        #expect(CodexModelsMetric.knownCost.shareBasisTitle == "known cost")
        #expect(CodexModelsMetric.sessionReferences.shareBasisTitle == "total session references")
    }

    @Test
    func `daily selection navigation anchors newest and clamps at range edges`() {
        let dates = (0..<4).map { day in
            Date(timeIntervalSinceReferenceDate: TimeInterval(day * 86400))
        }

        #expect(WorkspaceDailyUsageSelectionNavigator.movingDate(
            from: nil,
            direction: .earlier,
            availableDates: dates) == dates[2])
        #expect(WorkspaceDailyUsageSelectionNavigator.movingDate(
            from: nil,
            direction: .later,
            availableDates: dates) == dates[3])
        #expect(WorkspaceDailyUsageSelectionNavigator.movingDate(
            from: dates[0],
            direction: .earlier,
            availableDates: dates) == dates[0])
        #expect(WorkspaceDailyUsageSelectionNavigator.movingDate(
            from: dates[3],
            direction: .later,
            availableDates: dates) == dates[3])
        #expect(WorkspaceDailyUsageSelectionNavigator.movingDate(
            from: dates[2],
            direction: .earlier,
            availableDates: dates) == dates[1])
        #expect(WorkspaceDailyUsageSelectionNavigator.movingDate(
            from: dates[2],
            direction: .later,
            availableDates: dates) == dates[3])
    }

    @Test
    func `daily selection navigation handles empty and single day ranges`() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        #expect(WorkspaceDailyUsageSelectionNavigator.movingDate(
            from: nil,
            direction: .later,
            availableDates: []) == nil)
        #expect(WorkspaceDailyUsageSelectionNavigator.movingDate(
            from: nil,
            direction: .earlier,
            availableDates: [date]) == date)
        #expect(WorkspaceDailyUsageSelectionNavigator.movingDate(
            from: date,
            direction: .later,
            availableDates: [date]) == date)
    }

    @Test
    func `local day keys remain on their calendar day west and east of GMT`() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let losAngelesDate = WorkspaceDailyPoint.dateFromDayKey("2026-07-31", calendar: losAngeles)
        let losAngelesComponents = losAngeles.dateComponents([.year, .month, .day], from: losAngelesDate)
        let formatter = DateFormatter()
        formatter.calendar = losAngeles
        formatter.timeZone = losAngeles.timeZone
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let formattedDate = formatter.string(from: losAngelesDate)

        #expect(losAngelesComponents.year == 2026)
        #expect(losAngelesComponents.month == 7)
        #expect(losAngelesComponents.day == 31)
        #expect(formattedDate.contains("July 31"))
        #expect(!formattedDate.contains("July 30"))

        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let tokyoDate = WorkspaceDailyPoint.dateFromDayKey("2026-07-31", calendar: tokyo)
        let tokyoComponents = tokyo.dateComponents([.year, .month, .day], from: tokyoDate)
        #expect(tokyoComponents.year == 2026)
        #expect(tokyoComponents.month == 7)
        #expect(tokyoComponents.day == 31)
    }

    @Test
    func `project accessibility description includes severity and conditional cost`() {
        let withoutCost = CodexWorkspaceProjectAccessibilityDescription.make(
            projectName: "CodexBar",
            tokenText: "1.2K",
            severity: .elevated,
            estimatedCostText: nil,
            session: (3, "gpt-5"))
        #expect(withoutCost == [
            "CodexBar",
            L("codex_workspaces_token_count_accessibility", "1.2K"),
            CodexLocalUsageSeverity.elevated.workspaceAccessibilityDescription,
            L("codex_workspaces_session_count", 3),
            "gpt-5",
        ].joined(separator: ", "))

        let withCost = CodexWorkspaceProjectAccessibilityDescription.make(
            projectName: "CodexBar",
            tokenText: "1.2K",
            severity: .normal,
            estimatedCostText: "est. $1.00",
            session: (3, nil))
        #expect(withCost == [
            "CodexBar",
            L("codex_workspaces_token_count_accessibility", "1.2K"),
            CodexLocalUsageSeverity.normal.workspaceAccessibilityDescription,
            "est. $1.00",
            L("codex_workspaces_session_count", 3),
        ].joined(separator: ", "))
    }

    @Test
    func `protected snapshot keeps raw workspace and chat values out of presentation seams`() {
        let rawPath = "/Users/private.person/Developer/SecretWorkspace"
        let rawTitle = "Confidential acquisition planning"
        let totals = CodexLocalUsageTotals(
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 20,
            totalTokens: 120)
        let daily = CodexLocalUsageDailyPoint(
            day: "2026-07-31",
            totalTokens: 120,
            estimatedCostUSD: 0.25)
        let session = CodexLocalSessionUsage(
            id: "stable-session-id",
            projectId: "stable-workspace-id",
            displayTitle: CodexLocalSessionUsage.localChatFallbackTitle,
            cwd: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            latestActivity: Date(timeIntervalSince1970: 1_700_000_100),
            totals: totals,
            estimatedCostUSD: 0.25,
            hasUnknownCost: false,
            topModel: "gpt-5",
            daily: [daily])
        let project = CodexLocalProjectUsage(
            id: "stable-workspace-id",
            displayName: "Workspace",
            path: nil,
            totals: totals,
            estimatedCostUSD: 0.25,
            hasUnknownCost: false,
            sessionCount: 1,
            latestActivity: session.latestActivity,
            topModel: "gpt-5",
            topSessions: [session],
            modelBreakdowns: [],
            daily: [daily])
        let snapshot = CodexLocalProjectUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            historyDays: 30,
            scopeSignature: "stable-scope",
            rootsFingerprint: [:],
            indexedFileCount: 1,
            skippedFileCount: 0,
            total: totals,
            projects: [project],
            sessions: [session],
            daily: [daily])
        let presentation = CodexLocalProjectUsageWindowPresentation(
            snapshot: snapshot,
            selectedDestinationID: project.id,
            projection: CodexLocalProjectUsageProjection(
                includesCachedInput: true,
                showsEstimatedCost: true))
        let accessibility = CodexWorkspaceProjectAccessibilityDescription.make(
            projectName: presentation.rankedProjects[0].displayName,
            tokenText: presentation.sessions[0].tokenText,
            severity: presentation.rankedProjects[0].severity,
            estimatedCostText: nil,
            session: (presentation.sessionCount, presentation.topModel))
        let visibleAndAccessibleValues = [
            presentation.rankedProjects[0].displayName,
            presentation.rankedProjects[0].path ?? "—",
            presentation.sessions[0].title,
            presentation.sessions[0].path,
            presentation.daily[0].breakdownRows[0].title,
            accessibility,
        ].joined(separator: "\n")

        #expect(!visibleAndAccessibleValues.contains(rawPath))
        #expect(!visibleAndAccessibleValues.contains(rawTitle))
        #expect(presentation.selectedDestinationID == "stable-workspace-id")
        #expect(CodexWorkspaceSessionRows.filteredAndSorted(
            presentation.sessions,
            searchText: rawPath,
            selectedModel: "",
            sortOrder: []).isEmpty)
        #expect(CodexWorkspaceSessionRows.filteredAndSorted(
            presentation.sessions,
            searchText: rawTitle,
            selectedModel: "",
            sortOrder: []).isEmpty)
    }
}
