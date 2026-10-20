import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct AntigravityQuotaFamilyVisibilityTests {
    @Test
    func `unused Claude GPT quotas remain visible beside active Gemini`() {
        let usage = Self.snapshot(geminiUsed: 25, thirdPartyUsed: 0)

        #expect(AntigravityQuotaFamilyVisibility.idleWindowIDs(in: usage).isEmpty)
    }

    @Test
    func `all idle families remain visible`() {
        let usage = Self.snapshot(geminiUsed: 0, thirdPartyUsed: 0)

        #expect(AntigravityQuotaFamilyVisibility.idleWindowIDs(in: usage).isEmpty)
    }

    @Test
    func `unknown Claude GPT usage remains visible`() {
        let usage = Self.snapshot(geminiUsed: 25, thirdPartyUsed: 0, thirdPartyKnown: false)

        #expect(AntigravityQuotaFamilyVisibility.idleWindowIDs(in: usage).isEmpty)
    }

    @Test
    func `idle Gemini still hides beside active Claude GPT`() {
        let usage = Self.snapshot(geminiUsed: 0, thirdPartyUsed: 25)

        #expect(AntigravityQuotaFamilyVisibility.idleWindowIDs(in: usage) == [
            "antigravity-quota-summary-gemini-5h",
            "antigravity-quota-summary-gemini-weekly",
        ])
    }

    @Test
    func `idle unfamiliar families still hide beside active Gemini`() {
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                Self.lane(id: "gemini-5h", title: "Gemini 5-hour", used: 25),
                Self.lane(id: "example-5h", title: "Example 5-hour", used: 0),
                Self.lane(id: "example-weekly", title: "Example weekly", used: 0),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))

        #expect(AntigravityQuotaFamilyVisibility.idleWindowIDs(in: usage) == [
            "antigravity-quota-summary-example-5h",
            "antigravity-quota-summary-example-weekly",
        ])
    }

    @Test(arguments: [false, true])
    func `CLI cards show only supplied shared Claude GPT quotas`(includesThirdParty: Bool) {
        let usage = Self.snapshot(
            geminiUsed: 25,
            thirdPartyUsed: includesThirdParty ? 0 : nil)
        let card = CLICardsRenderer.makeCard(CLICardBuildInput(
            provider: .antigravity,
            snapshot: usage,
            credits: nil,
            source: "cli",
            status: nil,
            notes: [],
            useColor: false,
            resetStyle: .absolute,
            weeklyWorkDays: nil,
            now: usage.updatedAt))
        let output = CLICardsRenderer.render(cards: [card], failures: [], terminalWidth: 120, useColor: false)
        let text = CLIRenderer.renderText(
            provider: .antigravity,
            snapshot: usage,
            credits: nil,
            context: RenderContext(header: "Antigravity", status: nil, useColor: false, resetStyle: .absolute),
            now: usage.updatedAt)

        #expect(output.contains("Gemini 5-hour"))
        #expect(output.contains("Claude/GPT 5-hour") == includesThirdParty)
        #expect(output.contains("Claude/GPT weekly") == includesThirdParty)
        #expect(text.contains("Claude/GPT 5-hour") == includesThirdParty)
        #expect(text.contains("Claude/GPT weekly") == includesThirdParty)
        if includesThirdParty {
            #expect(output.contains("100% left"))
        }
    }

    @Test
    func `dashboard leaves unused Claude GPT quotas visible`() throws {
        let usage = Self.snapshot(geminiUsed: 25, thirdPartyUsed: 0)
        let payload = ProviderPayload(
            provider: .antigravity,
            account: nil,
            version: nil,
            source: "cli",
            status: nil,
            usage: usage,
            credits: nil,
            antigravityPlanInfo: nil,
            openaiDashboard: nil,
            error: nil)
        let dashboard = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [payload],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .antigravity, enabled: true)]),
            identityMode: .redacted,
            generatedAt: usage.updatedAt,
            refreshInterval: 60,
            codexBarVersion: nil)
        let json = try #require(CodexBarCLI.encodeJSON(dashboard, pretty: false))
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        let windows = try #require(provider["windows"] as? [[String: Any]])

        #expect(windows.count == 4)
        #expect(windows.allSatisfy { $0["idle"] == nil })
        #expect(windows.compactMap { $0["usedPercent"] as? Double } == [25, 25, 0, 0])
    }

    private static func snapshot(
        geminiUsed: Double,
        thirdPartyUsed: Double?,
        thirdPartyKnown: Bool = true) -> UsageSnapshot
    {
        var windows = [
            Self.lane(id: "gemini-5h", title: "Gemini 5-hour", used: geminiUsed),
            Self.lane(id: "gemini-weekly", title: "Gemini weekly", used: geminiUsed),
        ]
        if let thirdPartyUsed {
            windows.append(contentsOf: [
                Self.lane(
                    id: "3p-5h", title: "Claude/GPT 5-hour", used: thirdPartyUsed, known: thirdPartyKnown),
                Self.lane(
                    id: "3p-weekly", title: "Claude/GPT weekly", used: thirdPartyUsed, known: thirdPartyKnown),
            ])
        }
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: windows,
            updatedAt: Date(timeIntervalSince1970: 0))
    }

    private static func lane(id: String, title: String, used: Double, known: Bool = true) -> NamedRateWindow {
        NamedRateWindow(
            id: "antigravity-quota-summary-\(id)",
            title: title,
            window: RateWindow(
                usedPercent: used,
                windowMinutes: id.hasSuffix("weekly") ? 10080 : 300,
                resetsAt: nil,
                resetDescription: nil),
            usageKnown: known)
    }
}
