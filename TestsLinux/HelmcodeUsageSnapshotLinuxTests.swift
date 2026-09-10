#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCore

struct HelmcodeUsageSnapshotLinuxTests {
    @Test
    func `monthly quota maps to sorted model windows`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = HelmcodeQuotaResponse(
            periodStart: "2026-09-18T14:30:00Z",
            models: [
                HelmcodeModelQuota(
                    model: "helm-model-a",
                    cap: 1_000_000,
                    tokensUsed: 250_000,
                    creditTokens: 2000,
                    creditSpendMicros: 12500),
                HelmcodeModelQuota(
                    model: "helm-model-b",
                    cap: 2_000_000,
                    tokensUsed: 1_500_000,
                    creditTokens: 0,
                    creditSpendMicros: 0),
            ])
        let snapshot = HelmcodeUsageSnapshot(quota: quota, credits: nil, updatedAt: now).toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 75)
        #expect(snapshot.primary?.resetDescription?.contains("helm-model-b") == true)
        #expect(snapshot.extraRateWindows?.map(\.title) == ["helm-model-a"])
    }

    @Test
    func `usage above the cap clamps to one hundred percent and credits stay prepaid`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let quota = HelmcodeQuotaResponse(
            periodStart: "2026-09-01T00:00:00Z",
            models: [
                HelmcodeModelQuota(
                    model: "helm-model-a",
                    cap: 1_000_000,
                    tokensUsed: 1_500_000,
                    creditTokens: nil,
                    creditSpendMicros: nil),
            ])
        let credits = HelmcodeCreditsResponse(balanceMicros: 12_500_000, currency: "eur")
        let snapshot = HelmcodeUsageSnapshot(quota: quota, credits: credits, updatedAt: now).toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.providerCost?.used == 12.5)
        #expect(snapshot.providerCost?.currencyCode == "EUR")
        #expect(snapshot.providerCost?.period == "Prepaid balance")
    }
}
#endif
