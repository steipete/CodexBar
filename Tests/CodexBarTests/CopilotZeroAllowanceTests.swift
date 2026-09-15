import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CopilotZeroAllowanceTests {
    @Test
    func `hidden zero survives persistence and late allowance creation then hides again on clear`() async throws {
        let fixture = CopilotAllowanceFixture()
        defer { fixture.stop() }
        let receipt = try await CopilotZeroAllowanceProof.run(fixture: fixture, clearAtEnd: true)
        for (effect, correct) in receipt {
            #expect(correct, "\(effect)")
        }
    }
}

@MainActor
enum CopilotZeroAllowanceProof {
    static func run(fixture: CopilotAllowanceFixture, clearAtEnd: Bool) async throws -> [String: Bool] {
        let payload = #"""
        {"copilot_plan":"individual","token_based_billing":false,
         "quota_snapshots":{"premium_interactions":{
           "entitlement":300,"remaining":300,"percent_remaining":100,"credits_used":0}}}
        """#
        let response = try JSONDecoder().decode(CopilotUsageResponse.self, from: Data(payload.utf8))
        let fetched = try CopilotUsageFetcher(token: "fixture").snapshot(from: response)
        var receipt = ["hiddenInitially": fetched.details.isEmpty]
        let saved = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(fetched))
        receipt["zeroSurvivesPersistence"] = saved.copilotMeteredZeroCredits
        fixture.store.snapshots[.copilot] = saved
        fixture.store.lastKnownResetSnapshots[.copilot] = saved
        let gate = CopilotAllowanceResponseGate()
        fixture.store._test_providerFetchOutcomeOverride = { _ in
            await gate.wait()
            return ProviderFetchOutcome(
                result: .success(ProviderFetchResult(
                    usage: fetched,
                    credits: nil,
                    dashboard: nil,
                    sourceLabel: "fixture",
                    strategyID: "fixture",
                    strategyKind: .web)), attempts: [])
        }
        let refresh = Task { await fixture.store.refreshProvider(.copilot, allowDisabled: true) }
        while !gate.started {
            await Task.yield()
        }
        fixture.store.setCopilotSeatCreditEntitlement("3000")
        gate.resume()
        await refresh.value
        fixture.store._test_providerFetchOutcomeOverride = { _ in
            ProviderFetchOutcome(result: .failure(URLError(.notConnectedToInternet)), attempts: [])
        }
        await fixture.store.refreshProvider(.copilot, allowDisabled: true)
        receipt["lateAllowanceVisible"] = fixture.row?.progress?.total == 3000 && fixture.row?.usageValue == 0
        receipt["zeroSurvivesReplacement"] = fixture.store.snapshots[.copilot]?.copilotMeteredZeroCredits == true
        if clearAtEnd {
            fixture.store.setCopilotSeatCreditEntitlement("")
            receipt["hiddenAgainAfterClear"] = fixture.row == nil
        }
        receipt["quotaPreserved"] = fixture.store.snapshots[.copilot]?.primary == saved.primary
        receipt["timestampPreserved"] = fixture.store.snapshots[.copilot]?.updatedAt == saved.updatedAt
        return receipt
    }
}
