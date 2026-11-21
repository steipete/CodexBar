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

    @Test
    func `Notion exports named personal pools and keeps absent pools absent`() throws {
        for standardAvailable in [true, false] {
            let primary = standardAvailable ? RateWindow(
                usedPercent: 8.98,
                windowMinutes: 44640,
                resetsAt: Date(timeIntervalSince1970: 1_795_874_400),
                resetDescription: nil,
                quotaLimit: 1500,
                quotaUnit: "credits",
                title: "Standard") : nil
            let select = RateWindow(
                usedPercent: 0,
                windowMinutes: 44640,
                resetsAt: Date(timeIntervalSince1970: 1_795_874_400),
                resetDescription: nil,
                quotaLimit: 500,
                quotaUnit: "credits",
                title: "Select")
            let snapshot = UsageSnapshot(primary: primary, secondary: select, updatedAt: .distantPast)
            let data = try JSONEncoder().encode(Self.payload(providerID: "notion", usage: snapshot))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let labels = try #require(object["rateWindowLabels"] as? [String: String])
            #expect(labels ==
                (standardAvailable ? ["primary": "Standard", "secondary": "Select"] : ["secondary": "Select"]))
            let usage = try #require(object["usage"] as? [String: Any])
            let secondary = try #require(usage["secondary"] as? [String: Any])
            #expect(secondary["title"] as? String == "Select")
            #expect(secondary["quotaLimit"] as? Double == 500)
            #expect(secondary["windowMinutes"] as? Int == 44640)
        }
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
