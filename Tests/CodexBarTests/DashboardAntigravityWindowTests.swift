import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

/// The dashboard snapshot renders one Antigravity lane per quota bucket. The primary and secondary
/// representatives are copies of two of those buckets, kept only so the icon and menu bar have
/// standard slots to read, so the dashboard must not repeat them as rows of their own. Every family
/// stays in the payload for script clients, and the lanes of a family that reports no usage carry
/// `idle` so a display client can drop the same rows the menu card and the widget hide.
struct DashboardAntigravityWindowTests {
    @Test
    func `dashboard renders one Antigravity lane per quota bucket`() throws {
        let windows = try self.antigravityWindows(
            geminiSessionPercent: 3.9,
            geminiWeeklyPercent: 8.1,
            thirdPartySessionPercent: 1.5,
            thirdPartyWeeklyPercent: 2.5)

        #expect(windows.map { $0["label"] as? String } == [
            "Gemini 5-hour",
            "Gemini weekly",
            "Claude/GPT 5-hour",
            "Claude/GPT weekly",
        ])
        #expect(windows.map { $0["usedPercent"] as? Double } == [3.9, 8.1, 1.5, 2.5])
        // The key is absent rather than false, so a payload with no idle window keeps its old shape.
        #expect(windows.allSatisfy { $0["idle"] == nil })
    }

    @Test
    func `dashboard omits the Antigravity representative labels`() throws {
        let windows = try self.antigravityWindows(geminiSessionPercent: 3.9, geminiWeeklyPercent: 8.1)
        let labels = windows.compactMap { $0["label"] as? String }

        #expect(!labels.contains("Gemini Models"))
        #expect(!labels.contains("Claude and GPT"))
    }

    @Test
    func `dashboard marks an Antigravity family that reports no usage as idle`() throws {
        let windows = try self.antigravityWindows(geminiSessionPercent: 3.9, geminiWeeklyPercent: 8.1)

        // Every lane still ships, so a script client loses nothing.
        #expect(windows.map { $0["label"] as? String } == [
            "Gemini 5-hour",
            "Gemini weekly",
            "Claude/GPT 5-hour",
            "Claude/GPT weekly",
        ])
        #expect(windows.map { $0["idle"] as? Bool } == [nil, nil, true, true])
    }

    @Test
    func `dashboard marks no Antigravity family idle when none reports usage`() throws {
        let windows = try self.antigravityWindows(geminiSessionPercent: 0, geminiWeeklyPercent: 0)

        #expect(windows.count == 4)
        #expect(windows.allSatisfy { $0["idle"] == nil })
    }

    @Test
    func `dashboard leaves an Antigravity family with unknown usage unmarked`() throws {
        let windows = try self.antigravityWindows(
            geminiSessionPercent: 3.9,
            geminiWeeklyPercent: 8.1,
            thirdPartyUsageKnown: false)

        #expect(windows.count == 4)
        #expect(windows.allSatisfy { $0["idle"] == nil })
    }

    @Test
    func `dashboard keeps standard lanes for an Antigravity snapshot without summary windows`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: now, resetDescription: nil),
            secondary: RateWindow(usedPercent: 34, windowMinutes: 7 * 24 * 60, resetsAt: now, resetDescription: nil),
            tertiary: nil,
            updatedAt: now)

        let windows = try self.windows(for: usage, now: now)

        #expect(windows.map { $0["kind"] as? String } == ["session", "weekly"])
        #expect(windows.map { $0["label"] as? String } == ["Gemini Models", "Claude and GPT"])
    }

    // MARK: - Fixtures

    /// Mirrors the shape the quota-summary probe produces: four lanes, with `primary` and
    /// `secondary` set to the most-used lane of each family rather than to distinct windows.
    private func antigravityWindows(
        geminiSessionPercent: Double,
        geminiWeeklyPercent: Double,
        thirdPartySessionPercent: Double = 0,
        thirdPartyWeeklyPercent: Double = 0,
        thirdPartyUsageKnown: Bool = true) throws -> [[String: Any]]
    {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let geminiSession = RateWindow(
            usedPercent: geminiSessionPercent,
            windowMinutes: 300,
            resetsAt: now,
            resetDescription: nil)
        let geminiWeekly = RateWindow(
            usedPercent: geminiWeeklyPercent,
            windowMinutes: 7 * 24 * 60,
            resetsAt: now,
            resetDescription: nil)
        let thirdPartySession = RateWindow(
            usedPercent: thirdPartySessionPercent,
            windowMinutes: 300,
            resetsAt: now,
            resetDescription: nil)
        let thirdPartyWeekly = RateWindow(
            usedPercent: thirdPartyWeeklyPercent,
            windowMinutes: 7 * 24 * 60,
            resetsAt: now,
            resetDescription: nil)
        let extras = [
            NamedRateWindow(
                id: "antigravity-quota-summary-gemini-5h",
                title: "Gemini 5-hour",
                window: geminiSession,
                usageKnown: true),
            NamedRateWindow(
                id: "antigravity-quota-summary-gemini-weekly",
                title: "Gemini weekly",
                window: geminiWeekly,
                usageKnown: true),
            NamedRateWindow(
                id: "antigravity-quota-summary-3p-5h",
                title: "Claude/GPT 5-hour",
                window: thirdPartySession,
                usageKnown: thirdPartyUsageKnown),
            NamedRateWindow(
                id: "antigravity-quota-summary-3p-weekly",
                title: "Claude/GPT weekly",
                window: thirdPartyWeekly,
                usageKnown: thirdPartyUsageKnown),
        ]
        let usage = UsageSnapshot(
            primary: geminiWeeklyPercent >= geminiSessionPercent ? geminiWeekly : geminiSession,
            secondary: thirdPartySession,
            tertiary: nil,
            extraRateWindows: extras,
            updatedAt: now)

        return try self.windows(for: usage, now: now)
    }

    private func windows(for usage: UsageSnapshot, now: Date) throws -> [[String: Any]] {
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
        let snapshot = DashboardSnapshotBuilder.makeSnapshot(
            usagePayloads: [payload],
            costPayloads: [],
            config: CodexBarConfig(providers: [ProviderConfig(id: .antigravity, enabled: true)]),
            identityMode: .redacted,
            generatedAt: now,
            refreshInterval: 60,
            codexBarVersion: nil)

        let json = try #require(CodexBarCLI.encodeJSON(snapshot, pretty: false))
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let provider = try #require((object["providers"] as? [[String: Any]])?.first)
        return try #require(provider["windows"] as? [[String: Any]])
    }
}
