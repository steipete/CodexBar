import Testing
@testable import CodexBarCore

struct CursorLegacyRequestProjectionTests {
    @Test
    func `legacy plan hides token-based auto and api bars`() {
        let snapshot = Self.snapshot(requestsUsed: 347, requestsLimit: 500)

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(abs((usageSnapshot.primary?.usedPercent ?? 0) - 69.4) < 0.01)
        #expect(usageSnapshot.cursorRequests?.used == 347)
        #expect(usageSnapshot.cursorRequests?.limit == 500)
        #expect(usageSnapshot.secondary == nil)
        #expect(usageSnapshot.tertiary == nil)
    }

    @Test
    func `unusable legacy request quota preserves token bars`() {
        let requestCases: [(used: Int?, limit: Int?)] = [
            (nil, 500),
            (12, 0),
        ]

        for requestCase in requestCases {
            let usageSnapshot = Self.snapshot(
                requestsUsed: requestCase.used,
                requestsLimit: requestCase.limit).toUsageSnapshot()

            #expect(usageSnapshot.primary?.usedPercent == 7.0)
            #expect(usageSnapshot.cursorRequests == nil)
            #expect(usageSnapshot.secondary?.usedPercent == 11.0)
            #expect(usageSnapshot.tertiary?.usedPercent == 22.0)
        }
    }

    private static func snapshot(
        requestsUsed: Int?,
        requestsLimit: Int?) -> CursorStatusSnapshot
    {
        CursorStatusSnapshot(
            planPercentUsed: 7.0,
            autoPercentUsed: 11.0,
            apiPercentUsed: 22.0,
            planUsedUSD: 1.4,
            planLimitUSD: 20.0,
            onDemandUsedUSD: 0,
            onDemandLimitUSD: nil,
            teamOnDemandUsedUSD: nil,
            teamOnDemandLimitUSD: nil,
            billingCycleEnd: nil,
            membershipType: "pro",
            accountEmail: "user@example.com",
            accountName: nil,
            rawJSON: nil,
            requestsUsed: requestsUsed,
            requestsLimit: requestsLimit)
    }
}
