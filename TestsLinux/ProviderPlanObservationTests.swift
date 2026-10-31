import CodexBarCore
import Foundation
import Testing

struct ProviderPlanObservationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var observation: ProviderPlanObservation? {
        ProviderPlanObservation(rawPlan: "pro", source: .usageResponse, observedAt: self.now)
    }

    @Test
    func `observation requires a nonempty trimmed raw plan`() {
        #expect(ProviderPlanObservation(
            rawPlan: "  pro ",
            source: .usageResponse,
            observedAt: self.now)?.rawPlan == "pro")
        #expect(ProviderPlanObservation(rawPlan: nil, source: .usageResponse, observedAt: self.now) == nil)
        #expect(ProviderPlanObservation(rawPlan: "   ", source: .usageResponse, observedAt: self.now) == nil)
    }

    @Test
    func `snapshot coding round trips plan provenance and decodes old payloads`() throws {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: self.now,
            planObservation: self.observation)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        #expect(decoded.planObservation == self.observation)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "planObservation")
        let oldData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let oldDecoded = try JSONDecoder().decode(UsageSnapshot.self, from: oldData)
        #expect(oldDecoded.planObservation == nil)
    }

    @Test
    func `snapshot decoding tolerates an unknown future plan source`() throws {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: self.now,
            planObservation: self.observation)
        let data = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var planObject = try #require(object["planObservation"] as? [String: Any])
        planObject["source"] = "future_source"
        object["planObservation"] = planObject
        let futureData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: futureData)
        #expect(decoded.planObservation == nil)
        #expect(decoded.primary?.usedPercent == 12)
    }
}
