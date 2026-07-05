import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekUsageSnapshotAccountTests {
    private func snapshot(
        apiTotal: Double,
        account: DeepSeekAccountSummary?,
        identity: DeepSeekAccountIdentity?) -> DeepSeekUsageSnapshot
    {
        DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "USD",
            totalBalance: apiTotal,
            grantedBalance: 0,
            toppedUpBalance: apiTotal,
            usageSummary: nil,
            accountSummary: account,
            identity: identity,
            updatedAt: Date())
    }

    @Test
    func `to usage snapshot prefers account summary balance`() {
        let account = DeepSeekAccountSummary(
            currency: "CNY",
            paidBalance: 27.62,
            grantedBalance: 0,
            availableTokenEstimation: 9_208_044,
            monthlyCost: 0,
            monthlyTokenUsage: 0,
            updatedAt: Date())
        let usage = self.snapshot(apiTotal: 999, account: account, identity: nil).toUsageSnapshot()
        let detail = usage.primary?.resetDescription ?? ""
        #expect(detail.contains("¥27.62"))
        #expect(!detail.contains("tok"))
        #expect(usage.primary?.usedPercent == 0)
    }

    @Test
    func `balance below alert bound marks full`() {
        let account = DeepSeekAccountSummary(
            currency: "CNY",
            paidBalance: 0.5,
            grantedBalance: 0,
            availableTokenEstimation: nil,
            monthlyCost: nil,
            monthlyTokenUsage: nil,
            updatedAt: Date())
        let identity = DeepSeekAccountIdentity(
            email: "a@b.com",
            maskedMobile: nil,
            currency: "CNY",
            balanceAlertEnabled: true,
            balanceAlertBound: 1)
        let usage = self.snapshot(apiTotal: 0.5, account: account, identity: identity).toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0)
        #expect((usage.primary?.resetDescription ?? "").contains("below alert"))
        #expect(usage.identity?.accountEmail == "a@b.com")
    }

    @Test
    func `identity email flows into identity snapshot`() {
        let identity = DeepSeekAccountIdentity(
            email: "user@example.com",
            maskedMobile: nil,
            currency: "USD",
            balanceAlertEnabled: false,
            balanceAlertBound: nil)
        let usage = self.snapshot(apiTotal: 10, account: nil, identity: identity).toUsageSnapshot()
        #expect(usage.identity?.accountEmail == "user@example.com")
    }
}
