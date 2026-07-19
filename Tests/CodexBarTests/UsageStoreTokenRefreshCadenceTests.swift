import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreTokenRefreshCadenceTests {
    @Test(arguments: [
        (RefreshFrequency.oneMinute, 300.0),
        (.twoMinutes, 300.0),
        (.fiveMinutes, 300.0),
        (.fifteenMinutes, 900.0),
        (.thirtyMinutes, 1800.0),
    ])
    func `fixed refresh frequencies derive a widget-safe token TTL`(
        frequency: RefreshFrequency,
        expectedSeconds: TimeInterval)
    {
        #expect(UsageStore.tokenFetchTTL(for: frequency) == expectedSeconds)
    }

    @Test(arguments: [RefreshFrequency.adaptive, .adaptiveAgentAware])
    func `adaptive refresh frequencies use the policy nominal interval`(frequency: RefreshFrequency) {
        #expect(UsageStore.tokenFetchTTL(for: frequency) == AdaptiveRefreshPolicy.nominalIntervalForHeuristics)
    }

    @Test
    func `manual refresh disables the automatic token cadence`() {
        #expect(UsageStore.tokenFetchTTL(for: .manual) == nil)
    }
}
