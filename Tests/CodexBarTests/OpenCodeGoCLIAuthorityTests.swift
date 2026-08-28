import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct OpenCodeGoCLIAuthorityTests {
    @Test
    func `json identifies local quota windows as estimated`() throws {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 45, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 0, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            identity: nil,
            dataConfidence: .estimated)
        let payload = ProviderPayload(
            provider: .opencodego,
            account: nil,
            version: nil,
            source: "local",
            status: nil,
            usage: snapshot,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)

        let data = try JSONEncoder().encode([payload])
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let first = try #require(json.first)
        let usage = try #require(first["usage"] as? [String: Any])

        #expect(first["source"] as? String == "local")
        #expect(usage["dataConfidence"] as? String == "estimated")
    }

    @Test
    func `text output explains local quota estimates`() {
        let notes = CodexBarCLI.usageTextNotes(
            provider: .opencodego,
            sourceMode: .auto,
            resolvedSourceLabel: "local",
            dataConfidence: .estimated)

        #expect(notes == ["Quota estimated from local usage history"])
        #expect(CodexBarCLI.usageTextNotes(
            provider: .opencodego,
            sourceMode: .auto,
            resolvedSourceLabel: "local+web").isEmpty)
    }
}
