import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MiniMaxMenuCardModelPlanTests {
    @Test
    func `minimax loginMethod maps to planText in MenuCardModel`() throws {
        let now = Date()
        let minimax = MiniMaxUsageSnapshot(
            planName: "MiniMax Star",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            minimaxUsage: minimax,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "MiniMax Star"))
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

        #expect(model.planText == "MiniMax Star")
    }

    @Test
    func `minimax nil loginMethod results in nil planText`() throws {
        let now = Date()
        let minimax = MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            minimaxUsage: minimax,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .minimax,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))
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

        #expect(model.planText == nil)
    }

    @Test
    func `minimax quota rows include configured warning markers`() throws {
        let now = Date()
        let minimax = MiniMaxUsageSnapshot(
            planName: "TokenPlanPlus-年度会员",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now,
            services: [
                MiniMaxServiceUsage(
                    serviceType: "general",
                    windowType: "5 hours",
                    timeRange: "15:00-20:00(UTC+8)",
                    usage: 31,
                    limit: 100,
                    percent: 31,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: "Resets in 1 hour"),
                MiniMaxServiceUsage(
                    serviceType: "general",
                    windowType: "Weekly",
                    timeRange: "06/01 00:00 - 06/08 00:00(UTC+8)",
                    usage: 4,
                    limit: 100,
                    percent: 4,
                    resetsAt: now.addingTimeInterval(6 * 24 * 3600),
                    resetDescription: "Resets in 6 days"),
            ])
        let metadata = try #require(ProviderDefaults.metadata[.minimax])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: minimax.toUsageSnapshot(),
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
            quotaWarningThresholds: [.session: [50, 20], .weekly: [50, 20]],
            workDaysPerWeek: 5,
            now: now))

        #expect(model.metrics.map(\.warningMarkerPercents) == [[50, 80], [50, 80]])
        #expect(model.metrics.map(\.workdayMarkerPercents) == [[], [20, 40, 60, 80]])
    }

    @Test
    func `minimax quota rows use canonical general first order`() throws {
        let now = Date()
        let minimax = MiniMaxUsageSnapshot(
            planName: "TokenPlanMax-年度会员",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now,
            services: [
                MiniMaxServiceUsage(
                    serviceType: "video",
                    windowType: "Today",
                    timeRange: "06/01 00:00 - 06/02 00:00(UTC+8)",
                    usage: 70,
                    limit: 100,
                    percent: 70,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: "Resets in 1 hour"),
                MiniMaxServiceUsage(
                    serviceType: "general",
                    windowType: "5 hours",
                    timeRange: "15:00-20:00(UTC+8)",
                    usage: 4,
                    limit: 100,
                    percent: 4,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: "Resets in 1 hour"),
                MiniMaxServiceUsage(
                    serviceType: "general",
                    windowType: "Weekly",
                    timeRange: "06/01 00:00 - 06/08 00:00(UTC+8)",
                    usage: 1,
                    limit: 100,
                    percent: 1,
                    resetsAt: now.addingTimeInterval(6 * 24 * 3600),
                    resetDescription: "Resets in 6 days"),
            ])
        let metadata = try #require(ProviderDefaults.metadata[.minimax])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: minimax.toUsageSnapshot(),
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

        #expect(model.metrics.map(\.title) == ["General · 5h", "General · Weekly", "Video"])
        #expect(model.metrics.map(\.percent) == [4, 1, 70])
    }

    @Test
    func `minimax unlimited quota rows omit usage copy and warning markers`() throws {
        let now = Date()
        let minimax = MiniMaxUsageSnapshot(
            planName: "Plus",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now,
            services: [
                MiniMaxServiceUsage(
                    serviceType: "general",
                    windowType: "5 hours",
                    timeRange: "15:00-20:00(UTC+8)",
                    usage: 2,
                    limit: 200,
                    percent: 2,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: "Resets in 1 hour"),
                MiniMaxServiceUsage(
                    serviceType: "general",
                    windowType: "Weekly",
                    timeRange: "06/01 00:00 - 06/08 00:00(UTC+8)",
                    usage: 0,
                    limit: 0,
                    percent: 0,
                    isUnlimited: true,
                    resetsAt: nil,
                    resetDescription: "Unlimited"),
            ])
        let metadata = try #require(ProviderDefaults.metadata[.minimax])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .minimax,
            metadata: metadata,
            snapshot: minimax.toUsageSnapshot(),
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
            quotaWarningThresholds: [.session: [50, 20], .weekly: [50, 20]],
            now: now))

        #expect(model.metrics.count == 2)
        #expect(model.metrics[1].title == "General · Weekly")
        #expect(model.metrics[1].statusText == "∞ Unlimited")
        #expect(model.metrics[1].detailLeftText == nil)
        #expect(model.metrics[1].warningMarkerPercents == [])
    }
}
