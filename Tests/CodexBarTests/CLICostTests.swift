import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLICostTests {
    @Test
    func `cost json shortcut does not enable json logs`() throws {
        let signature = CodexBarCLI._costSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--json"])

        #expect(parsed.flags.contains("jsonShortcut"))
        #expect(!parsed.flags.contains("jsonOutput"))
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }

    @Test
    func `renders cost text snapshot`() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 90,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CodexBarCLI.renderCostText(provider: .claude, snapshot: snap, useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")

        #expect(output.contains("Claude Cost (API-rate estimate)"))
        #expect(output.contains("Today: $1.25 · 1.2K tokens"))
        #expect(output.contains("Last 90 days: $9.99 · 9K tokens"))
        #expect(output.contains("cache read/write tokens"))
        #expect(output.contains("Claude Code /status"))
    }

    @Test
    func `renders codex project grouped cost text`() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 30,
            daily: [],
            projects: [
                CostUsageProjectBreakdown(
                    name: "client-a",
                    path: "/work/client-a",
                    totalTokens: 7000,
                    totalCostUSD: 7.5,
                    daily: [],
                    modelBreakdowns: nil,
                    sources: [
                        CostUsageProjectSourceBreakdown(
                            name: "client-a",
                            path: "/work/client-a",
                            totalTokens: 5000,
                            totalCostUSD: 5.25,
                            daily: [],
                            modelBreakdowns: nil),
                        CostUsageProjectSourceBreakdown(
                            name: "client-a",
                            path: "/Users/test/.codex/worktrees/abcd/client-a",
                            totalTokens: 2000,
                            totalCostUSD: 2.25,
                            daily: [],
                            modelBreakdowns: nil),
                    ]),
                CostUsageProjectBreakdown(
                    name: CostUsageProjectBreakdown.unknownProjectName,
                    path: nil,
                    totalTokens: 2000,
                    totalCostUSD: 2.49,
                    daily: [],
                    modelBreakdowns: nil),
            ],
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CodexBarCLI.renderCostText(
            provider: .codex,
            snapshot: snap,
            groupBy: .project,
            useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")

        #expect(output.contains("Codex API-equivalent estimate (not billed)"))
        #expect(output.contains("Projects (Last 30 days):"))
        #expect(output.contains("client-a: $7.50 · 7K tokens"))
        #expect(output.contains("/work/client-a"))
        #expect(output.contains("  - client-a: $5.25 · 5K tokens"))
        #expect(output.contains("  - client-a: $2.25 · 2K tokens"))
        #expect(output.contains("/Users/test/.codex/worktrees/abcd/client-a"))
        #expect(output.contains("Unknown project: $2.49 · 2K tokens"))
        #expect(output.contains("Not a subscription bill or plan value · local usage × public API prices"))
    }

    @Test
    func `encodes cost payload JSON`() throws {
        let payload = CostPayload(
            provider: "claude",
            source: "local",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionTokens: 100,
            sessionCostUSD: 0.5,
            historyDays: 90,
            last30DaysTokens: 200,
            last30DaysCostUSD: 1.5,
            daily: [
                CostDailyEntryPayload(
                    date: "2025-12-20",
                    inputTokens: 10,
                    outputTokens: 5,
                    cacheReadTokens: 2,
                    cacheCreationTokens: 3,
                    totalTokens: 15,
                    costUSD: 0.01,
                    modelsUsed: ["claude-sonnet-4-20250514"],
                    modelBreakdowns: [
                        CostModelBreakdownPayload(
                            modelName: "claude-sonnet-4-20250514",
                            costUSD: 0.01,
                            totalTokens: 15),
                    ]),
            ],
            totals: CostTotalsPayload(
                totalInputTokens: 10,
                totalOutputTokens: 5,
                cacheReadTokens: 2,
                cacheCreationTokens: 3,
                totalTokens: 15,
                totalCostUSD: 0.01),
            error: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode cost payload JSON")
            return
        }

        #expect(json.contains("\"provider\":\"claude\""))
        #expect(json.contains("\"source\":\"local\""))
        #expect(json.contains("\"historyDays\":90"))
        #expect(json.contains("\"daily\""))
        #expect(json.contains("\"totals\""))
        #expect(json.contains("\"cacheReadTokens\":2"))
        #expect(json.contains("\"cacheCreationTokens\":3"))
        #expect(json.contains("\"totalCost\""))
        #expect(json.contains("\"totalTokens\":15"))
        #expect(json.contains("1700000000"))
    }

    @Test
    func `codex cost payload includes project rollups`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.01,
            last30DaysTokens: 40,
            last30DaysCostUSD: 0.04,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-02",
                    inputTokens: 30,
                    outputTokens: 10,
                    totalTokens: 40,
                    costUSD: 0.04,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 0.04,
                            totalTokens: 40),
                    ]),
            ],
            projects: [
                CostUsageProjectBreakdown(
                    name: "client-a",
                    path: "/work/client-a",
                    totalTokens: 40,
                    totalCostUSD: 0.04,
                    daily: [
                        CostUsageDailyReport.Entry(
                            date: "2026-04-02",
                            inputTokens: 30,
                            outputTokens: 10,
                            totalTokens: 40,
                            costUSD: 0.04,
                            modelsUsed: ["gpt-5.4"],
                            modelBreakdowns: nil),
                    ],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 0.04,
                            totalTokens: 40),
                    ],
                    sources: [
                        CostUsageProjectSourceBreakdown(
                            name: "client-a",
                            path: "/work/client-a",
                            totalTokens: 40,
                            totalCostUSD: 0.04,
                            daily: [
                                CostUsageDailyReport.Entry(
                                    date: "2026-04-02",
                                    inputTokens: 30,
                                    outputTokens: 10,
                                    totalTokens: 40,
                                    costUSD: 0.04,
                                    modelsUsed: ["gpt-5.4"],
                                    modelBreakdowns: nil),
                            ],
                            modelBreakdowns: nil),
                    ]),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let payload = CodexBarCLI.makeCostPayload(provider: .codex, snapshot: snapshot, error: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode cost payload JSON")
            return
        }

        #expect(json.contains("\"projects\""))
        #expect(json.contains("\"sources\""))
        #expect(json.contains("\"name\":\"client-a\""))
        #expect(json.contains("/work/client-a") || json.contains("\\/work\\/client-a"))
        #expect(json.contains("\"totalCost\":0.04"))
        #expect(json.contains("\"daily\""))
        #expect(json.contains("\"gpt-5.4\""))
    }

    @Test
    func `encodes exact codex model I ds and zero cost breakdowns`() throws {
        let payload = CostPayload(
            provider: "codex",
            source: "local",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionTokens: 155,
            sessionCostUSD: 0,
            historyDays: 30,
            last30DaysTokens: 155,
            last30DaysCostUSD: 0,
            daily: [
                CostDailyEntryPayload(
                    date: "2025-12-21",
                    inputTokens: 120,
                    outputTokens: 15,
                    cacheReadTokens: 20,
                    cacheCreationTokens: nil,
                    totalTokens: 155,
                    costUSD: 0,
                    modelsUsed: ["gpt-5.3-codex-spark", "gpt-5.2-codex"],
                    modelBreakdowns: [
                        CostModelBreakdownPayload(modelName: "gpt-5.3-codex-spark", costUSD: 0, totalTokens: 15),
                        CostModelBreakdownPayload(modelName: "gpt-5.2-codex", costUSD: 1.23, totalTokens: 140),
                    ]),
            ],
            totals: CostTotalsPayload(
                totalInputTokens: 120,
                totalOutputTokens: 15,
                cacheReadTokens: 20,
                cacheCreationTokens: nil,
                totalTokens: 155,
                totalCostUSD: 0),
            error: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to decode cost payload JSON")
            return
        }

        #expect(json.contains("\"gpt-5.3-codex-spark\""))
        #expect(json.contains("\"gpt-5.2-codex\""))
        #expect(!json.contains("\"gpt-5.2\""))
        #expect(json.contains("\"cost\":0"))
        #expect(json.contains("\"totalTokens\":140"))
    }

    @Test
    func `cost estimate hint is stable string`() {
        let hint = UsageFormatter.costEstimateHint
        #expect(!hint.isEmpty)
        #expect(hint.contains("Estimated"))
        #expect(UsageFormatter.costEstimateHint(provider: .claude).contains("cache read/write tokens"))
    }

    @Test
    func `cursor cookie source off produces a failed JSON payload`() throws {
        let settings = ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: .off,
            manualCookieHeader: nil)
        let error = try #require(CodexBarCLI.cursorCostAvailabilityError(.cursor, settings: settings))
        let payload = CodexBarCLI.makeCostPayload(provider: .cursor, snapshot: nil, error: error)
        let json = try #require(CodexBarCLI.encodeJSON([payload], pretty: false))

        #expect(CodexBarCLI.mapError(error) == .failure)
        #expect(json.contains("\"provider\":\"cursor\""))
        #expect(json.contains("\"code\":1"))
        #expect(json.contains("cookie source is set to Off"))
        #expect(CodexBarCLI.cursorCostAvailabilityError(.cursor, settings: nil) == nil)
        #expect(CodexBarCLI.cursorCostAvailabilityError(.codex, settings: settings) == nil)
    }

    @Test
    func `cursor manual cookie source rejects an empty header`() throws {
        let settings = ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: .manual,
            manualCookieHeader: "  ")
        let error = try #require(CodexBarCLI.cursorCostAvailabilityError(.cursor, settings: settings))

        #expect(CodexBarCLI.mapError(error) == .failure)
        #expect(error.localizedDescription.contains("non-empty Manual cookie header"))
        #expect(CodexBarCLI.cursorCostHeaderOverride(.cursor, settings: settings) == nil)
    }

    @Test
    func `cursor settings resolution errors fail closed`() throws {
        let resolutionError = CursorCostSettingsTestError()
        let error = try #require(CodexBarCLI.cursorCostAvailabilityError(
            .cursor,
            settings: nil,
            resolutionError: resolutionError))

        #expect(error.localizedDescription == resolutionError.localizedDescription)
        #expect(CodexBarCLI.cursorCostAvailabilityError(
            .codex,
            settings: nil,
            resolutionError: resolutionError) == nil)
    }
}

private struct CursorCostSettingsTestError: LocalizedError {
    var errorDescription: String? {
        "Cursor settings resolution failed."
    }
}
