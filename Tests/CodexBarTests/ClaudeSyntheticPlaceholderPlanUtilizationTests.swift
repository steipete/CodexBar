import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension UsageStorePlanUtilizationTests {
    @MainActor
    @Test
    func `Claude placeholder is omitted from session history while weekly history continues`() async {
        let store = Self.makeStore()
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 5 * 60,
                resetsAt: now.addingTimeInterval(2 * 60 * 60),
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: RateWindow(
                usedPercent: 42,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "placeholder-history@example.com",
                accountOrganization: nil,
                loginMethod: "web"))

        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: snapshot, now: now)

        let histories = store.planUtilizationHistory(for: .claude)
        #expect(findSeries(histories, name: .session, windowMinutes: 5 * 60) == nil)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 7 * 24 * 60)?
            .entries.map(\.usedPercent) == [42])
    }
}
