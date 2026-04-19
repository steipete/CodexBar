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
        let weekly = try #require(row.secondaryLine)
        #expect(weekly.contains("Weekly"))
        #expect(weekly.contains("91.7"))
        // Remaining uses UsageFormatter.tokenCountString (e.g. 70646 → "71K"), not raw digits.
        #expect(weekly.contains("remaining"))
    }

    @Test
    func `minimax hides weekly secondary line when weekly quota is zero zero`() throws {
        let now = Date()
        let models: [MiniMaxModelUsage] = [
            MiniMaxModelUsage(
                identifier: "coding",
                displayName: "Coding",
                availablePrompts: 1000,
                currentPrompts: 100,
                remainingPrompts: 900,
                windowMinutes: 300,
                usedPercent: 10,
                resetsAt: nil,
                weeklyTotal: 0,
                weeklyUsed: 0,
                weeklyRemaining: 0,
                weeklyUsedPercent: nil,
                weeklyResetsAt: nil,
                window: .fiveHour),
        ]
        let minimax = MiniMaxUsageSnapshot(
            planName: "Plan",
            availablePrompts: 1000,
            currentPrompts: 100,
            remainingPrompts: 900,
            windowMinutes: 300,
            usedPercent: 10,
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
        let row = try #require(sections.first?.rows.first)
        #expect(row.secondaryLine == nil)
    }

    @Test @MainActor
    func `collapse store defaults collapsed when row count at least five`() {
        let store = MiniMaxSectionCollapseStore.shared
        store.resetOverridesForTesting()
        #expect(store.isCollapsed(sectionTitle: "Daily quota", rowCount: MiniMaxUILayoutMetrics.collapseThreshold))
        #expect(store.isCollapsed(sectionTitle: "Daily quota", rowCount: 10))
        #expect(!store.isCollapsed(sectionTitle: "Daily quota", rowCount: MiniMaxUILayoutMetrics.collapseThreshold - 1))
    }

    @Test @MainActor
    func `collapse store toggle persists until reset`() {
        let store = MiniMaxSectionCollapseStore.shared
        store.resetOverridesForTesting()
        #expect(store.isCollapsed(sectionTitle: "Daily quota", rowCount: MiniMaxUILayoutMetrics.collapseThreshold))
        store.toggle(sectionTitle: "Daily quota", rowCount: MiniMaxUILayoutMetrics.collapseThreshold)
        #expect(!store.isCollapsed(sectionTitle: "Daily quota", rowCount: MiniMaxUILayoutMetrics.collapseThreshold))
        store.toggle(sectionTitle: "Daily quota", rowCount: MiniMaxUILayoutMetrics.collapseThreshold)
        #expect(store.isCollapsed(sectionTitle: "Daily quota", rowCount: MiniMaxUILayoutMetrics.collapseThreshold))
        store.resetOverridesForTesting()
        #expect(store.isCollapsed(sectionTitle: "Daily quota", rowCount: MiniMaxUILayoutMetrics.collapseThreshold))
    }

    @Test @MainActor
    func `collapse store user override beats default for small sections`() {
        let store = MiniMaxSectionCollapseStore.shared
        store.resetOverridesForTesting()
        #expect(!store.isCollapsed(sectionTitle: "Other windows", rowCount: 2))
        store.toggle(sectionTitle: "Other windows", rowCount: 2)
        #expect(store.isCollapsed(sectionTitle: "Other windows", rowCount: 2))
    }

    @Test
    func `minimax detail line does not infer full usage when interval usage count missing`() {
        let row = MiniMaxModelUsage(
            identifier: "m",
            displayName: "M",
            availablePrompts: 1000,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: 300,
            usedPercent: 12.0,
            resetsAt: nil,
            weeklyTotal: nil,
            weeklyUsed: nil,
            weeklyRemaining: nil,
            weeklyUsedPercent: nil,
            weeklyResetsAt: nil,
            window: .fiveHour)
        let line = UsageMenuCardView.Model.miniMaxDetailLine(model: row)
        let totalStr = UsageFormatter.tokenCountString(1000)
        #expect(line == "—/\(totalStr)")
    }

    @Test
    func `minimax detail line derives used from remaining when current omitted`() {
        let row = MiniMaxModelUsage(
            identifier: "m",
            displayName: "M",
            availablePrompts: 1000,
            currentPrompts: nil,
            remainingPrompts: 250,
            windowMinutes: 300,
            usedPercent: 75.0,
            resetsAt: nil,
            weeklyTotal: nil,
            weeklyUsed: nil,
            weeklyRemaining: nil,
            weeklyUsedPercent: nil,
            weeklyResetsAt: nil,
            window: .fiveHour)
        let line = UsageMenuCardView.Model.miniMaxDetailLine(model: row)
        let usedStr = UsageFormatter.tokenCountString(750)
        let totalStr = UsageFormatter.tokenCountString(1000)
        let remStr = UsageFormatter.tokenCountString(250)
        #expect(line == "\(usedStr)/\(totalStr) (\(remStr) remaining)")
    }
}
