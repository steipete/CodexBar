import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexExtraUsageFreshnessTests {
    let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test(arguments: [true, false])
    func `attached dashboard zero clears stale balance but an unread balance preserves it`(read: Bool) throws {
        let dashboard = self.dashboard(balance: read ? 0 : nil, date: self.now)
        let attached = CodexExtraUsageCost.attaching(
            to: self.usage(), credits: dashboard.toCreditsSnapshot())
        let live = CreditsSnapshot(remaining: 50, events: [], updatedAt: self.now.addingTimeInterval(-60))
        let model = try self.card(snapshot: attached, live: live)
        let cost = try #require(model.providerCost)
        #expect(cost.balanceLine == (read ? nil : "Balance: 50"))
        #expect(cost.spendLine == "Monthly credit limit: 300 / 400")
        #expect(cost.percentUsed == 75)
    }

    @Test
    func `balance timestamp survives a cap with a different age`() throws {
        let old = self.now.addingTimeInterval(-120)
        let middle = self.now.addingTimeInterval(-60)
        let attached = ProviderCostSnapshot(
            used: 100,
            limit: 400,
            currencyCode: CodexExtraUsageCost.currencyCode,
            balance: nil,
            balanceUpdatedAt: self.now,
            updatedAt: old)
        let live = CreditsSnapshot(
            remaining: 50,
            events: [],
            updatedAt: middle,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 200, limit: 400, remainingPercent: 50, resetsAt: nil, updatedAt: middle))
        let resolved = try #require(CodexExtraUsageCost.resolving(liveCredits: live, attached: attached))
        #expect(resolved.used == 200)
        #expect(resolved.updatedAt == middle)
        #expect(resolved.balance == nil)
        #expect(resolved.balanceUpdatedAt == self.now)
        let decoded = try JSONDecoder().decode(ProviderCostSnapshot.self, from: JSONEncoder().encode(resolved))
        #expect(decoded == resolved)
        #expect(CodexExtraUsageCost.resolving(liveCredits: live, attached: decoded)?.balance == nil)
    }

    @Test
    func `confirmed purchased-only zero survives attachment and hides extra usage`() throws {
        let old = CodexExtraUsageCost.attaching(
            to: self.usage(),
            credits: CreditsSnapshot(remaining: 50, events: [], updatedAt: self.now.addingTimeInterval(-60)))
        let empty = CodexExtraUsageCost.attaching(
            to: old, credits: CreditsSnapshot(remaining: 0, events: [], updatedAt: self.now))
        #expect(empty.providerCost?.balance == nil)
        #expect(empty.providerCost?.balanceUpdatedAt == self.now)
        let model = try self.card(
            snapshot: empty,
            live: CreditsSnapshot(remaining: 50, events: [], updatedAt: self.now.addingTimeInterval(-60)))
        #expect(model.providerCost == nil)
    }

    @Test
    func `legacy cost payload keeps positive balance freshness without inventing a zero`() throws {
        let cost = ProviderCostSnapshot(
            used: 100,
            limit: 400,
            currencyCode: CodexExtraUsageCost.currencyCode,
            balance: 50,
            updatedAt: self.now)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cost)) as? [String: Any])
        object.removeValue(forKey: "balanceUpdatedAt")
        let decoded = try JSONDecoder().decode(
            ProviderCostSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.balanceUpdatedAt == nil)
        let stale = CreditsSnapshot(remaining: 0, events: [], updatedAt: self.now.addingTimeInterval(-60))
        #expect(CodexExtraUsageCost.resolving(liveCredits: stale, attached: decoded)?.balance == 50)
    }

    @Test
    func `real monthly quota never borrows extra credit detail`() throws {
        let snapshot = self.usage(primary: RateWindow(
            usedPercent: 80, windowMinutes: 43200, resetsAt: nil, resetDescription: nil))
        let model = try self.card(
            snapshot: snapshot,
            live: self.dashboard(balance: 50, date: self.now).toCreditsSnapshot())
        let monthly = try #require(model.metrics.first { $0.id == "monthly" })
        #expect(monthly.percent == 80)
        #expect(monthly.detailText == nil)
    }

    @Test(arguments: [true, false])
    func `synthetic monthly bar and detail select the same fresh cap`(attachedIsNewer: Bool) throws {
        let old = self.now.addingTimeInterval(-60)
        let attached = CodexExtraUsageCost.attaching(
            to: self.usage(),
            credits: self.dashboard(balance: 50, date: attachedIsNewer ? self.now : old).toCreditsSnapshot())
        let live = CreditsSnapshot(
            remaining: 50,
            events: [],
            updatedAt: attachedIsNewer ? old : self.now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 120,
                limit: 400,
                remainingPercent: 70,
                resetsAt: nil,
                updatedAt: attachedIsNewer ? old : self.now))
        let model = try self.card(snapshot: attached, live: live)
        let monthly = try #require(model.metrics.first { $0.id == "monthly" })
        #expect(monthly.percent == (attachedIsNewer ? 75 : 30))
        #expect(monthly.detailText == (attachedIsNewer ? "300 / 400" : "120 / 400"))
    }

    @Test(arguments: [true, false])
    func `live card and menu bar do not resurrect the older legacy credit balance`(read: Bool) {
        let old = CreditsSnapshot(remaining: 50, events: [], updatedAt: self.now.addingTimeInterval(-60))
        let new = CreditsSnapshot(remaining: 0, events: [], updatedAt: self.now, balanceReadSucceeded: read)
        let snapshot = CodexExtraUsageCost.attaching(to: self.usage(), credits: new)
        for surface in [CodexConsumerProjection.Surface.liveCard, .menuBar] {
            let projection = CodexConsumerProjection.make(
                surface: surface,
                context: .init(
                    snapshot: snapshot,
                    rawUsageError: nil,
                    liveCredits: old,
                    rawCreditsError: nil,
                    liveDashboard: nil,
                    rawDashboardError: nil,
                    dashboardAttachmentAuthorized: false,
                    dashboardRequiresLogin: false,
                    now: self.now))
            #expect(projection.credits?.remaining == (read ? 0 : 50))
            #expect(projection.credits?.snapshot?.events == old.events)
        }
        #expect(old.remaining == 50)
    }

    func usage(primary: RateWindow? = nil) -> UsageSnapshot {
        UsageSnapshot(primary: primary, secondary: nil, updatedAt: self.now)
    }

    func dashboard(balance: Double?, date: Date) -> OpenAIDashboardSnapshot {
        OpenAIDashboardSnapshot(
            signedInEmail: nil,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: balance,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 300,
                limit: 400,
                remainingPercent: 25,
                resetsAt: self.now.addingTimeInterval(3600),
                updatedAt: date),
            updatedAt: date)
    }

    func card(snapshot: UsageSnapshot, live: CreditsSnapshot?) throws -> UsageMenuCardView.Model {
        let projection = CodexConsumerProjection.make(
            surface: .overrideCard,
            context: .init(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: live,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: self.now))
        return try UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: #require(ProviderDefaults.metadata[.codex]),
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "fixture@example.com", plan: "business"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: self.now))
    }
}
