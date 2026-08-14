import CodexBarCore
import Foundation
import Testing

struct OpenCodeCostPresentationTests {
    private func costStyle(limit: Double, balance: Double?) -> ProviderCostMenuCardStyle {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 15,
                limit: limit,
                currencyCode: "USD",
                period: "Monthly",
                balance: balance,
                updatedAt: now),
            updatedAt: now,
            identity: nil)
        return ProviderDescriptorRegistry.descriptor(for: .opencode)
            .presentation
            .cost(snapshot: snapshot)
            .menuCardStyle
    }

    @Test
    func `pay as you go workspace without a limit selects the spend style`() {
        #expect(self.costStyle(limit: 0, balance: 12.5) == .payAsYouGoSpend)
    }

    @Test
    func `workspace with a monthly limit keeps the generic budget style`() {
        #expect(self.costStyle(limit: 20, balance: 12.5) == .generic)
    }

    @Test
    func `missing provider cost keeps the generic budget style`() {
        let now = Date()
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: now, identity: nil)
        let style = ProviderDescriptorRegistry.descriptor(for: .opencode)
            .presentation
            .cost(snapshot: snapshot)
            .menuCardStyle
        #expect(style == .generic)
    }
}
