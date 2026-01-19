import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

@Suite
struct CLICostTests {
    @Test
    func costJsonShortcutDoesNotEnableJsonLogs() throws {
        let signature = CodexBarCLI._costSignatureForTesting()
        let parser = CommandParser(signature: signature)
        let parsed = try parser.parse(arguments: ["--json"])

        #expect(parsed.flags.contains("jsonShortcut"))
        #expect(!parsed.flags.contains("jsonOutput"))
        #expect(CodexBarCLI._decodeFormatForTesting(from: parsed) == .json)
    }

    @Test
    func rendersCostTextSnapshot() {
        let snap = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CodexBarCLI.renderCostText(provider: .claude, snapshot: snap, useColor: false)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "$ ", with: "$")

        #expect(output.contains("Claude Cost (local)"))
        #expect(output.contains("Today: $1.25 · 1.2K tokens"))
        #expect(output.contains("Last 30 days: $9.99 · 9K tokens"))
    }

    @Test
    func encodesCostPayloadJSON() throws {
        let payload = CostPayload(
            provider: "claude",
            source: "local",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessionTokens: 100,
            sessionCostUSD: 0.5,
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
                        CostModelBreakdownPayload(modelName: "claude-sonnet-4-20250514", costUSD: 0.01),
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
        #expect(json.contains("\"daily\""))
        #expect(json.contains("\"totals\""))
        #expect(json.contains("\"cacheReadTokens\":2"))
        #expect(json.contains("\"cacheCreationTokens\":3"))
        #expect(json.contains("\"totalCost\""))
        #expect(json.contains("1700000000"))
    }
}
