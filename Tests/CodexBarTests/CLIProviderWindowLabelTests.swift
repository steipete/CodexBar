import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIProviderWindowLabelTests {
    @Test
    func `sparse v0 quota exports its rate limit label without inventing a primary window or cadence`() throws {
        let usage = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 0))
        let data = try JSONEncoder().encode(Self.payload(providerID: "v0", usage: usage))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let labels = try #require(object["rateWindowLabels"] as? [String: String])
        #expect(labels == ["secondary": "Rate limit"])
        let encodedUsage = try #require(object["usage"] as? [String: Any])
        #expect(encodedUsage["primary"] is NSNull)
        let secondary = try #require(encodedUsage["secondary"] as? [String: Any])
        #expect(secondary["windowMinutes"] == nil)
    }

    @Test
    func `unknown providers and absent usage do not inherit built in window labels`() {
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 0))
        #expect(Self.payload(providerID: "fixture-custom-provider", usage: usage).rateWindowLabels == nil)
        #expect(Self.payload(providerID: "v0", usage: nil).rateWindowLabels == nil)
    }

    private static func payload(providerID: String, usage: UsageSnapshot?) -> ProviderPayload {
        ProviderPayload(
            providerID: providerID,
            account: nil,
            version: nil,
            source: "fixture",
            status: nil,
            usage: usage,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
    }
}
