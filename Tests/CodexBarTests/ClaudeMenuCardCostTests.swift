import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ClaudeMenuCardCostTests {
    private static let now = Date(timeIntervalSince1970: 1_782_000_000)

    @Test(arguments: [false, true])
    func `capped extra usage uses one metric with caption reset and pace`(showUsed: Bool) throws {
        let model = try Self.makeModel(cost: Self.cost(used: 25, limit: 100, balance: 20), showUsed: showUsed)
        let metric = try #require(model.metrics.first)
        #expect(model.providerCost == nil)
        #expect(model.metrics.count == 1)
        #expect(metric.id == "claude-extra-usage")
        #expect(metric.percent == (showUsed ? 25 : 75))
        #expect(metric.percentStyle == (showUsed ? .used : .left))
        #expect(metric.detailText == "Monthly cap: $25.00 / $100.00 · Balance: $20.00")
        #expect(metric.resetText == "Resets in 10d")
        #expect(metric.detailRightText == "Lasts until reset")
        #expect(metric.pacePercent != nil)
        #expect(metric.helpText?.contains("00:00 UTC on the 1st") == true)
    }

    @MainActor
    @Test
    func `monthly cap keeps the existing extra usage visibility and pace gates`() throws {
        let model = try Self.makeModel(cost: Self.cost(used: 40, limit: 100), showUsed: true, paceVisible: false)
        let metric = try #require(model.metrics.first)
        #expect(metric.detailText == "Monthly cap: $40.00 / $100.00")
        #expect(metric.resetText != nil)
        #expect(metric.pacePercent == nil)
        #expect(metric.detailRightText == nil)
        #expect(model.usageItemDescriptors.contains { $0.id == .claudeExtraUsage && $0.requiresOptionalUsage })
        #expect(model.applyingUsageItemVisibility(hiddenItemIDs: [.claudeExtraUsage]).metrics.isEmpty)
    }

    @Test(arguments: [0.0, -1.0], [false, true])
    func `claude balance only card stays compact`(limit: Double, showUsed: Bool) throws {
        let model = try Self.makeModel(cost: Self.cost(used: 0, limit: limit, balance: 100), showUsed: showUsed)
        let section = try #require(model.providerCost)

        #expect(section.title == "Credits")
        #expect(section.spendLine == "$100.00")
        #expect(section.balanceLine == nil)
        #expect(section.percentUsed == nil)
        #expect(section.displayPercent == nil)
        #expect(section.percentLine == nil)
        #expect(section.presentation == .inlineValue)
        #expect(section.showsInProviderDetails == false)
    }

    @MainActor
    @Test
    func `claude balance only credits follow the extra usage visibility choice`() throws {
        let model = try Self.makeModel(cost: Self.cost(used: 0, limit: 0, balance: 100), showUsed: true)
        #expect(model.usageItemDescriptors.contains { $0.id == .claudeExtraUsage && $0.title == "Credits" })
        let hidden = model.applyingUsageItemVisibility(hiddenItemIDs: [.claudeExtraUsage])
        #expect(hidden.providerCost == nil)
    }

    @Test(arguments: [0.0, -1.0], [false, true])
    func `claude extra usage without a positive cap or balance stays absent`(limit: Double, showUsed: Bool) throws {
        let model = try Self.makeModel(cost: Self.cost(used: 25, limit: limit), showUsed: showUsed)
        #expect(model.providerCost == nil)
    }

    @Test(arguments: [false, true])
    func `claude missing cost stays absent`(showUsed: Bool) throws {
        let model = try Self.makeModel(cost: nil, showUsed: showUsed)
        #expect(model.providerCost == nil)
    }

    @Test(arguments: [0.0, 100.0], [false, true])
    func `claude optional extra usage and balances stay hidden`(limit: Double, showUsed: Bool) throws {
        let model = try Self.makeModel(
            cost: Self.cost(used: 25, limit: limit, balance: 100),
            showUsed: showUsed,
            showOptional: false)
        #expect(model.providerCost == nil)
        #expect(model.metrics.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func `claude admin api spend remains visible without prepaid balance`(
        showUsed: Bool,
        showOptional: Bool) throws
    {
        let model = try Self.makeModel(
            cost: Self.cost(used: 12.34, limit: 0, period: "Last 30 days"),
            showUsed: showUsed,
            showOptional: showOptional,
            isAdminAPI: true)
        let section = try #require(model.providerCost)

        #expect(section.title == "API spend")
        #expect(section.spendLine == "Last 30 days: $12.34")
        #expect(section.percentUsed == nil)
        #expect(section.displayPercent == nil)
        #expect(section.percentLine == nil)
        #expect(section.presentation == .detail)
        #expect(section.showsInProviderDetails == true)
    }

    @Test(arguments: [false, true])
    func `claude admin api spend still follows summary visibility`(showUsed: Bool) throws {
        let model = try Self.makeModel(
            cost: Self.cost(used: 12.34, limit: 0, period: "Last 30 days"),
            showUsed: showUsed,
            isAdminAPI: true,
            costSummaryInlineEnabled: false)
        #expect(model.providerCost == nil)
    }

    @Test(arguments: [ProviderCostMenuCardStyle.generic, .clawRouter], [false, true])
    func `other capped provider costs keep used fill`(style: ProviderCostMenuCardStyle, showUsed: Bool) throws {
        let section = try #require(UsageMenuCardView.Model.providerCostSection(
            cost: Self.cost(used: 25, limit: 100),
            style: style,
            percentStyle: showUsed ? .used : .left,
            preferredCurrencyCode: "USD"))

        #expect(section.percentStyle == .used)
        #expect(section.percentUsed == 25)
        #expect(section.displayPercent == 25)
        #expect(section.progressAccessibilityLabel == "Extra usage spent")
        #expect(section.spendLine == "Monthly cap: $25.00 / $100.00")
        #expect(section.percentLine == "25% used")
    }

    private static func cost(
        used: Double,
        limit: Double,
        balance: Double? = nil,
        period: String = "Monthly cap") -> ProviderCostSnapshot
    {
        ProviderCostSnapshot(
            used: used,
            limit: limit,
            currencyCode: "USD",
            period: period,
            balance: balance,
            updatedAt: self.now)
    }

    private static func makeModel(
        cost: ProviderCostSnapshot?,
        showUsed: Bool,
        showOptional: Bool = true,
        isAdminAPI: Bool = false,
        costSummaryInlineEnabled: Bool = true,
        paceVisible: Bool = true) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: cost,
            updatedAt: self.now,
            identity: isAdminAPI ? ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Admin API") : nil)
        return UsageMenuCardView.Model.make(.init(
            provider: .claude,
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
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: costSummaryInlineEnabled,
            showOptionalCreditsAndExtraUsage: showOptional,
            hidePersonalInfo: true,
            paceVisible: paceVisible,
            preferredCurrencyCode: "USD",
            now: self.now))
    }
}
