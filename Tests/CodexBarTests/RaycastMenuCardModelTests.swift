import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct RaycastMenuCardModelTests {
    @Test
    func `raycast card keeps one credits meter with the balance under the bar`() throws {
        let now = Date(timeIntervalSince1970: 1_779_000_000)
        let renewal = Date(timeIntervalSince1970: 1_792_000_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 32.654,
                windowMinutes: nil,
                resetsAt: renewal,
                resetDescription: "336.73 / 500 credits left"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .raycast,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))
        let metadata = try #require(ProviderDefaults.metadata[.raycast])

        func model(showUsed: Bool, resetStyle: ResetTimeDisplayStyle) -> UsageMenuCardView.Model {
            UsageMenuCardView.Model.make(.init(
                provider: .raycast,
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
                usageBarsShowUsed: showUsed,
                resetTimeDisplayStyle: resetStyle,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                now: now))
        }

        let remaining = model(showUsed: false, resetStyle: .countdown)
        let primary = try #require(remaining.metrics.first)
        #expect(remaining.usageNotes.isEmpty)
        #expect(remaining.subscriptionNotes.isEmpty)
        #expect(remaining.providerDetails.isEmpty)
        #expect(remaining.metrics.map(\.title) == ["Credits"])
        #expect(primary.title == "Credits")
        #expect(primary.linePresentation(title: primary.title).titleText == "Credits 67% left")
        #expect(primary.detailText == "336.73 / 500 credits left")
        #expect(try primary.resetText == UsageFormatter.resetLine(
            for: #require(snapshot.primary),
            style: .countdown,
            now: now))
        #expect(primary.resetText?.hasPrefix("Resets") == true)

        let used = model(showUsed: true, resetStyle: .absolute)
        let usedMetric = try #require(used.metrics.first)
        #expect(usedMetric.linePresentation(title: usedMetric.title).titleText == "Credits 33% used")
        #expect(usedMetric.detailText == "336.73 / 500 credits left")
        #expect(try usedMetric.resetText == UsageFormatter.resetLine(
            for: #require(snapshot.primary),
            style: .absolute,
            now: now))
        #expect(usedMetric.resetText?.hasPrefix("Resets") == true)
    }

    @Test
    func `raycast card keeps credit rows when there is no meter`() throws {
        let now = Date(timeIntervalSince1970: 1_779_000_000)
        let renewal = Date(timeIntervalSince1970: 1_792_000_000)
        let snapshot = try UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            details: [
                ProviderDetailSection(
                    title: "Credits",
                    rows: [
                        ProviderDetailSection.Row(label: "Left", value: "0"),
                        ProviderDetailSection.Row(label: "Total", value: "0"),
                    ]),
            ],
            subscriptionRenewsAt: renewal,
            updatedAt: now)
        let metadata = try #require(ProviderDefaults.metadata[.raycast])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .raycast,
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

        #expect(model.metrics.isEmpty)
        #expect(model.providerDetails.map(\.title) == ["Credits"])
        #expect(model.providerDetails[0].rows.map(\.label) == ["Left", "Total"])
        #expect(model.subscriptionNotes.count == 1)
        #expect(model.subscriptionNotes[0].hasPrefix("Renews: "))
    }
}
