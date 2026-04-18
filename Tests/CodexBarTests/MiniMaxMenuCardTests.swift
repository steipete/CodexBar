import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MiniMaxMenuCardTests {
    @Test
    func `minimax sections group fiveHour and daily rows`() throws {
        let now = Date()
        let models: [MiniMaxModelUsage] = [
            MiniMaxModelUsage(
                identifier: "text-gen",
                displayName: "Text",
                availablePrompts: 4500,
                currentPrompts: 100,
                remainingPrompts: 4400,
                windowMinutes: 300,
                usedPercent: 2.2,
                resetsAt: nil,
                weeklyTotal: nil,
                weeklyUsed: nil,
                weeklyRemaining: nil,
                weeklyUsedPercent: nil,
                weeklyResetsAt: nil,
                window: .fiveHour),
            MiniMaxModelUsage(
                identifier: "image-01",
                displayName: "image-01",
                availablePrompts: 120,
                currentPrompts: 0,
                remainingPrompts: 120,
                windowMinutes: 1440,
                usedPercent: 0,
                resetsAt: nil,
                weeklyTotal: nil,
                weeklyUsed: nil,
                weeklyRemaining: nil,
                weeklyUsedPercent: nil,
                weeklyResetsAt: nil,
                window: .daily),
        ]
        let minimax = MiniMaxUsageSnapshot(
            planName: "Token Plan",
            availablePrompts: 4500,
            currentPrompts: 100,
            remainingPrompts: 4400,
            windowMinutes: 300,
            usedPercent: 2.2,
            resetsAt: nil,
            updatedAt: now,
            models: models)
        let snapshot = minimax.toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.minimax])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let sections = try #require(model.minimaxSections)
        #expect(sections.count == 2)
        #expect(sections[0].title == "5-hour window")
        #expect(sections[0].rows.count == 1)
        #expect(sections[0].rows[0].title == "Text")
        #expect(sections[1].title == "Daily quota")
        #expect(sections[1].rows[0].title == "image-01")
    }

    @Test
    func `minimax shows sections when single row has weekly quota`() throws {
        let now = Date()
        let models: [MiniMaxModelUsage] = [
            MiniMaxModelUsage(
                identifier: "speech-hd",
                displayName: "Speech HD",
                availablePrompts: 11000,
                currentPrompts: 10995,
                remainingPrompts: 5,
                windowMinutes: 1440,
                usedPercent: 99.95,
                resetsAt: nil,
                weeklyTotal: 77000,
                weeklyUsed: 6354,
                weeklyRemaining: 70646,
                weeklyUsedPercent: 91.7,
                weeklyResetsAt: nil,
                window: .daily),
        ]
        let minimax = MiniMaxUsageSnapshot(
            planName: "Token Plan",
            availablePrompts: 11000,
            currentPrompts: 10995,
            remainingPrompts: 5,
            windowMinutes: 1440,
            usedPercent: 99.95,
            resetsAt: nil,
            updatedAt: now,
            models: models)
        let snapshot = minimax.toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.minimax])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let sections = try #require(model.minimaxSections)
        #expect(sections.count == 1)
        let row = try #require(sections.first?.rows.first)
        #expect(row.secondaryLine?.contains("Weekly") == true)
        #expect(row.secondaryLine?.contains("70646") == true)
    }
}
