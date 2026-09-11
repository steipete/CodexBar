import Foundation
import Testing
@testable import CodexBarCore

struct CodexWorkspaceBalanceReconciliationTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func credits(balance: Double, workspace: Bool, read: Bool = true) -> CreditsSnapshot {
        CreditsSnapshot(
            remaining: balance,
            events: [],
            updatedAt: self.now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 300,
                limit: 400,
                remainingPercent: 25,
                resetsAt: nil,
                updatedAt: self.now),
            balanceReadSucceeded: read,
            creditsAvailable: true,
            balanceIsWorkspace: workspace)
    }

    @Test
    func `workspace balances equal to a monthly remainder survive cost reconciliation`() throws {
        let workspace = self.credits(balance: 100, workspace: true)
        let cost = try #require(CodexExtraUsageCost.providerCost(from: workspace))
        #expect(cost.balance == 100)
        #expect(cost.balanceIsWorkspace == true)

        let hidden = self.credits(balance: 0, workspace: false, read: false)
        let display = try #require(CodexExtraUsageCost.creditsForDisplay(hidden, attached: cost))
        #expect(display.remaining == 100)
        #expect(display.hasWorkspaceBalance)
        #expect(display.displayRemaining == 100)
    }

    @Test
    func `a fresh hidden pool invalidates an older attached workspace balance but preserves its cap`() throws {
        let hidden = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: self.now,
            balanceReadSucceeded: false,
            creditsAvailable: true)
        for limit in [0.0, 400.0] {
            let stale = ProviderCostSnapshot(
                used: 0,
                limit: limit,
                currencyCode: CodexExtraUsageCost.currencyCode,
                balance: 1234,
                balanceIsWorkspace: true,
                updatedAt: self.now.addingTimeInterval(-60))
            let cost = CodexExtraUsageCost.resolving(liveCredits: hidden, attached: stale)
            #expect(cost?.balance == nil)
            #expect(cost?.balanceUpdatedAt == nil)
            #expect(cost?.limit == (limit > 0 ? limit : nil))
            let snapshot = UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: stale,
                updatedAt: self.now)
            let attached = CodexExtraUsageCost.attaching(to: snapshot, credits: hidden)
            #expect(attached.providerCost == cost)
            let display = try #require(CodexExtraUsageCost.creditsForDisplay(hidden, attached: stale))
            #expect(!display.balanceReadSucceeded)
            #expect(display.displayRemaining == (limit > 0 ? limit : nil))
        }
    }

    @Test
    func `a cap only refresh still preserves a cached workspace balance`() throws {
        let capOnly = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: self.now,
            codexCreditLimit: self.credits(balance: 0, workspace: false).codexCreditLimit,
            balanceReadSucceeded: false)
        let stale = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: CodexExtraUsageCost.currencyCode,
            balance: 1234,
            balanceIsWorkspace: true,
            updatedAt: self.now.addingTimeInterval(-60))
        let display = try #require(CodexExtraUsageCost.creditsForDisplay(capOnly, attached: stale))
        #expect(display.displayRemaining == 1234)
        #expect(display.hasWorkspaceBalance)
    }

    @Test
    func `only explicit workspace provenance overrides the monthly display`() {
        #expect(self.credits(balance: 0, workspace: false).displayRemaining == 100)
        #expect(self.credits(balance: 14, workspace: false).displayRemaining == 100)
        #expect(self.credits(balance: 0, workspace: true).displayRemaining == 0)
        #expect(self.credits(balance: 1234, workspace: true).displayRemaining == 1234)
        #expect(self.credits(balance: 0, workspace: true, read: false).displayRemaining == 100)
    }

    @Test
    func `a newer workspace zero clears a cached positive balance and retains its source`() throws {
        let workspace = self.credits(balance: 0, workspace: true)
        let stale = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: CodexExtraUsageCost.currencyCode,
            balance: 1234,
            balanceIsWorkspace: true,
            updatedAt: self.now.addingTimeInterval(-60))
        let cost = try #require(CodexExtraUsageCost.resolving(liveCredits: workspace, attached: stale))
        #expect(cost.balance == nil)
        #expect(cost.balanceIsWorkspace == true)
        #expect(cost.balanceUpdatedAt == self.now)
    }

    @Test
    func `a newer ordinary balance does not inherit cached workspace provenance`() throws {
        let credits = self.credits(balance: 14, workspace: false)
        let stale = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: CodexExtraUsageCost.currencyCode,
            balance: 1234,
            balanceIsWorkspace: true,
            updatedAt: self.now.addingTimeInterval(-60))
        let cost = try #require(CodexExtraUsageCost.resolving(liveCredits: credits, attached: stale))
        #expect(cost.balance == 14)
        #expect(cost.balanceIsWorkspace != true)
    }

    @Test
    func `workspace provenance survives persistence and defaults off in legacy snapshots`() throws {
        let credits = self.credits(balance: 1234, workspace: true)
        let encoded = try JSONEncoder().encode(credits)
        #expect(try JSONDecoder().decode(CreditsSnapshot.self, from: encoded) == credits)
        let cost = try #require(CodexExtraUsageCost.providerCost(from: credits))
        #expect(try JSONDecoder().decode(ProviderCostSnapshot.self, from: JSONEncoder().encode(cost)) == cost)

        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "balanceIsWorkspace")
        legacy.removeValue(forKey: "creditsAvailable")
        let decoded = try JSONDecoder().decode(
            CreditsSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!decoded.balanceIsWorkspace)
        #expect(decoded.creditsAvailable == nil)
        #expect(decoded.displayRemaining == 100)
    }
}
