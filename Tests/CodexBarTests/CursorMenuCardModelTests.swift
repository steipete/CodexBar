import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CursorMenuCardModelTests {
    @Test
    func `chosen app session account identity is visible on the card`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .cursor,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Cursor Pro",
                accountID: "auth0|app-user"))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "web@example.com", plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.email == "app-user")
    }

    @Test
    func `team pool shows personal spend and changes height fingerprint`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])

        #expect(metadata.supportsCredits == false)

        func makeModel(
            personalUsed: Double?,
            showOptionalUsage: Bool = true) -> UsageMenuCardView.Model
        {
            let snapshot = UsageSnapshot(
                primary: nil,
                secondary: nil,
                tertiary: nil,
                providerCost: ProviderCostSnapshot(
                    used: 13111.25,
                    limit: 20000,
                    currencyCode: "USD",
                    period: "Monthly",
                    personalUsed: personalUsed,
                    updatedAt: now),
                updatedAt: now,
                identity: nil)
            return UsageMenuCardView.Model.make(.init(
                provider: .cursor,
                metadata: metadata,
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: showOptionalUsage,
                hidePersonalInfo: false,
                now: now))
        }

        let personal = makeModel(personalUsed: 44.71)
        let absent = makeModel(personalUsed: nil)
        let zero = makeModel(personalUsed: 0)
        let hidden = makeModel(personalUsed: 44.71, showOptionalUsage: false)

        #expect(personal.creditsText == nil)
        #expect(personal.providerCost?.title == "Extra usage")
        #expect(personal.providerCost?.personalSpendLine == "Your spend: $44.71")
        #expect(absent.providerCost?.personalSpendLine == nil)
        #expect(zero.providerCost?.personalSpendLine == nil)
        #expect(hidden.providerCost == nil)
        #expect(personal.heightFingerprint(section: "card") != absent.heightFingerprint(section: "card"))
        #expect(!personal.hasCompatibleTrackedLayout(with: absent))
        #expect(!absent.hasCompatibleTrackedLayout(with: personal))
    }

    @Test
    func `cursor billing cycle metrics show deficit and run out details`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let cycleMinutes = 30 * 24 * 60
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 90, windowMinutes: cycleMinutes, resetsAt: reset, resetDescription: nil),
            secondary: RateWindow(usedPercent: 90, windowMinutes: cycleMinutes, resetsAt: reset, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 90, windowMinutes: cycleMinutes, resetsAt: reset, resetDescription: nil),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
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

        #expect(model.metrics.map(\.title) == ["Total", "Cursor", "Third Party"])
        for metric in model.metrics {
            #expect(metric.percentLabel == "10% left")
            #expect(metric.detailLeftText == "10% in deficit")
            #expect(metric.detailRightText == "Runs out in 2d 16h")
            #expect(metric.pacePercent == 20)
            #expect(metric.paceOnTop == false)
        }
    }

    @Test
    func `cursor billing cycle metrics hide pace when quota is depleted`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let cycleMinutes = 30 * 24 * 60
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: cycleMinutes, resetsAt: reset, resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 100,
                windowMinutes: cycleMinutes,
                resetsAt: reset,
                resetDescription: nil),
            tertiary: RateWindow(usedPercent: 100, windowMinutes: cycleMinutes, resetsAt: reset, resetDescription: nil),
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
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

        #expect(model.metrics.map(\.title) == ["Total", "Cursor", "Third Party"])
        for metric in model.metrics {
            #expect(metric.percentLabel == "0% left")
            #expect(metric.detailLeftText == nil)
            #expect(metric.detailRightText == nil)
            #expect(metric.pacePercent == nil)
        }
    }

    @Test
    func `legacy request plan shows single requests bar with count`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        let cycleMinutes = 30 * 24 * 60
        // A legacy snapshot, as produced by CursorStatusSnapshot.toUsageSnapshot(): only the request
        // window survives, Auto/API are dropped, and the request count rides along.
        let snapshot = try UsageSnapshot(
            primary: RateWindow(
                usedPercent: 69.4,
                windowMinutes: cycleMinutes,
                resetsAt: reset,
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            details: [ProviderDetailSection(rows: [
                ProviderDetailSection.Row(label: "Request quota", value: "347 / 500"),
            ])],
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
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

        #expect(model.metrics.map(\.title) == ["Requests"])
        #expect(model.metrics.first?.detailText == "Request quota: 347 / 500")
    }

    @Test
    func `grok bot extra window renders after monthly bars`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let monthlyReset = now.addingTimeInterval(26 * 24 * 3600)
        let weeklyReset = now.addingTimeInterval(3 * 24 * 3600)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 1, windowMinutes: 43200, resetsAt: monthlyReset, resetDescription: nil),
            secondary: RateWindow(usedPercent: 1, windowMinutes: 43200, resetsAt: monthlyReset, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 0, windowMinutes: 43200, resetsAt: monthlyReset, resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: CursorSandUsageStatus.extraWindowID,
                    title: CursorSandUsageStatus.extraWindowTitle,
                    window: RateWindow(
                        usedPercent: 100,
                        windowMinutes: 10080,
                        resetsAt: weeklyReset,
                        resetDescription: nil)),
            ],
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
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

        #expect(model.metrics.map(\.title) == ["Total", "Cursor", "Third Party", "Grok Bot"])
        #expect(model.metrics.last?.percentLabel == "0% left")
        #expect(model.metrics.last?.detailLeftText == nil)
        #expect(model.metrics.last?.detailRightText == nil)
    }

    @Test(arguments: [3.0, 28.0])
    func `cursor monthly pace stays separate from grok bot after a billing reset`(cursorUsedPercent: Double) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let monthlyReset = now.addingTimeInterval(TimeInterval((28 * 24 + 14) * 3600))
        let monthlyMinutes = 36 * 60 + (28 * 24 + 14) * 60
        let grokReset = now.addingTimeInterval(TimeInterval((2 * 24 + 14) * 3600))
        let grokWindow = RateWindow(
            usedPercent: 28,
            windowMinutes: 10080,
            resetsAt: grokReset,
            resetDescription: nil)
        let grokPace = try #require(UsagePace.weekly(window: grokWindow, now: now))
        #expect(Int(abs(grokPace.deltaPercent).rounded()) == 35)

        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 3,
                windowMinutes: monthlyMinutes,
                resetsAt: monthlyReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: cursorUsedPercent,
                windowMinutes: monthlyMinutes,
                resetsAt: monthlyReset,
                resetDescription: nil),
            tertiary: RateWindow(
                usedPercent: 16,
                windowMinutes: monthlyMinutes,
                resetsAt: monthlyReset,
                resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: CursorSandUsageStatus.extraWindowID,
                    title: CursorSandUsageStatus.extraWindowTitle,
                    window: grokWindow),
            ],
            updatedAt: now,
            identity: nil)
        let semantic = CursorProviderDescriptor.descriptor.presentation.semanticWindows(snapshot: snapshot)
        #expect(semantic.weekly?.usedPercent == cursorUsedPercent)
        #expect(semantic.weekly?.windowMinutes == monthlyMinutes)
        let monthlyWindow = try #require(semantic.weekly)
        let monthlyPace = try #require(UsagePace.weekly(window: monthlyWindow, now: now))

        let metadata = try #require(ProviderDefaults.metadata[.cursor])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
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
            weeklyPace: monthlyPace,
            now: now))

        let metrics = Dictionary(uniqueKeysWithValues: model.metrics.map { ($0.title, $0) })
        #expect(metrics["Total"]?.detailLeftText == "On pace")
        #expect(metrics["Cursor"]?.detailLeftText == (cursorUsedPercent == 3 ? "On pace" : "23% in deficit"))
        #expect(metrics["Third Party"]?.detailLeftText == "11% in deficit")
        #expect(metrics["Grok Bot"]?.detailLeftText == "35% in reserve")
        #expect(metrics["Grok Bot"]?.detailRightText == "Lasts until reset")
        #expect(metrics["Grok Bot"]?.pacePercent != nil)
    }

    @Test
    func `trial grok bot extra window has no weekly pace`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let monthlyReset = now.addingTimeInterval(TimeInterval((28 * 24 + 14) * 3600))
        let monthlyMinutes = 36 * 60 + (28 * 24 + 14) * 60
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 3,
                windowMinutes: monthlyMinutes,
                resetsAt: monthlyReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 3,
                windowMinutes: monthlyMinutes,
                resetsAt: monthlyReset,
                resetDescription: nil),
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: CursorSandUsageStatus.extraWindowID,
                    title: CursorSandUsageStatus.extraWindowTitle,
                    window: RateWindow(
                        usedPercent: 28,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: now,
            identity: nil)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
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

        let grok = try #require(model.metrics.first(where: { $0.title == "Grok Bot" }))
        #expect(grok.detailLeftText == nil)
        #expect(grok.detailRightText == nil)
        #expect(grok.pacePercent == nil)
    }
}
