import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexHistoricalPricingProofTests {
    private struct SessionFixture {
        let day: Date
        let filename: String
        let sessionID: String
        let model: String
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["CODEXBAR_SPEND_PROOF_DIR"] != nil,
        "Set CODEXBAR_SPEND_PROOF_DIR to write historical pricing proof artifacts."))
    func `writes redacted real scan proof for GPT56 historical pricing`() async throws {
        let dir = try #require(ProcessInfo.processInfo.environment["CODEXBAR_SPEND_PROOF_DIR"])

        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let beforeDay = try env.makeLocalNoon(year: 2026, month: 7, day: 29)
        let afterDay = try env.makeLocalNoon(year: 2026, month: 7, day: 30)

        try self.writeCodexSession(
            env: env,
            fixture: SessionFixture(
                day: beforeDay,
                filename: "terra-before.jsonl",
                sessionID: "before-terra",
                model: "openai/gpt-5.6-terra"))
        try self.writeCodexSession(
            env: env,
            fixture: SessionFixture(
                day: afterDay,
                filename: "terra-after.jsonl",
                sessionID: "after-terra",
                model: "openai/gpt-5.6-terra"))
        try self.writeCodexSession(
            env: env,
            fixture: SessionFixture(
                day: beforeDay,
                filename: "luna-before.jsonl",
                sessionID: "before-luna",
                model: "openai/gpt-5.6-luna"))
        try self.writeCodexSession(
            env: env,
            fixture: SessionFixture(
                day: afterDay,
                filename: "luna-after.jsonl",
                sessionID: "after-luna",
                model: "openai/gpt-5.6-luna"))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: afterDay.addingTimeInterval(86400),
            historyDays: 3,
            allowPricingRefresh: false,
            scannerOptions: options,
            piScannerOptions: piOptions)

        let terraBefore = try #require(self.lookup(snapshot: snapshot, day: "2026-07-29", model: "gpt-5.6-terra"))
        let terraAfter = try #require(self.lookup(snapshot: snapshot, day: "2026-07-30", model: "gpt-5.6-terra"))
        let lunaBefore = try #require(self.lookup(snapshot: snapshot, day: "2026-07-29", model: "gpt-5.6-luna"))
        let lunaAfter = try #require(self.lookup(snapshot: snapshot, day: "2026-07-30", model: "gpt-5.6-luna"))

        let terraBeforeExpected = (90.0 * 2.5e-6) + (10.0 * 2.5e-7) + (5.0 * 1.5e-5)
        let terraAfterExpected = (90.0 * 2e-6) + (10.0 * 2e-7) + (5.0 * 1.2e-5)
        let lunaBeforeExpected = (90.0 * 1e-6) + (10.0 * 1e-7) + (5.0 * 6e-6)
        let lunaAfterExpected = (90.0 * 2e-7) + (10.0 * 2e-8) + (5.0 * 1.2e-6)
        let terraBeforeCost = try #require(terraBefore.costUSD)
        let terraAfterCost = try #require(terraAfter.costUSD)
        let lunaBeforeCost = try #require(lunaBefore.costUSD)
        let lunaAfterCost = try #require(lunaAfter.costUSD)
        #expect(abs(terraBeforeCost - terraBeforeExpected) < 1e-7)
        #expect(abs(terraAfterCost - terraAfterExpected) < 1e-7)
        #expect(abs(lunaBeforeCost - lunaBeforeExpected) < 1e-7)
        #expect(abs(lunaAfterCost - lunaAfterExpected) < 1e-7)
        #expect((terraBefore.costUSD ?? 0) > (terraAfter.costUSD ?? 0))
        #expect((lunaBefore.costUSD ?? 0) > (lunaAfter.costUSD ?? 0))

        let proofRoot = URL(
            fileURLWithPath: NSString(string: dir).expandingTildeInPath,
            isDirectory: true)
        try FileManager.default.createDirectory(at: proofRoot, withIntermediateDirectories: true)

        let rows: [[String: Any]] = [
            self.redactedProofRow(day: "2026-07-29", model: "gpt-5.6-terra", breakdown: terraBefore),
            self.redactedProofRow(day: "2026-07-30", model: "gpt-5.6-terra", breakdown: terraAfter),
            self.redactedProofRow(day: "2026-07-29", model: "gpt-5.6-luna", breakdown: lunaBefore),
            self.redactedProofRow(day: "2026-07-30", model: "gpt-5.6-luna", breakdown: lunaAfter),
        ]
        let jsonObject: [String: Any] = [
            "cutoffUTC": "2026-07-30T00:00:00Z",
            "source": "CostUsageFetcher.loadTokenSnapshot(provider: .codex)",
            "fixture": "local synthetic codex JSONL sessions scanned through the real scanner path",
            "rows": rows,
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(
            to: proofRoot.appendingPathComponent("codex-historical-pricing-proof.json"),
            options: .atomic)

        let log = """
        source: CostUsageFetcher.loadTokenSnapshot(provider: .codex)
        cutoffUTC: 2026-07-30T00:00:00Z
        fixture: local synthetic codex JSONL sessions scanned through the real scanner path
        2026-07-29 gpt-5.6-terra costUSD=\(terraBefore.costUSD ?? -1) totalTokens=\(terraBefore.totalTokens)
        2026-07-30 gpt-5.6-terra costUSD=\(terraAfter.costUSD ?? -1) totalTokens=\(terraAfter.totalTokens)
        2026-07-29 gpt-5.6-luna costUSD=\(lunaBefore.costUSD ?? -1) totalTokens=\(lunaBefore.totalTokens)
        2026-07-30 gpt-5.6-luna costUSD=\(lunaAfter.costUSD ?? -1) totalTokens=\(lunaAfter.totalTokens)
        """
        try log.write(
            to: proofRoot.appendingPathComponent("codex-historical-pricing-proof.log"),
            atomically: true,
            encoding: .utf8)
    }

    private func writeCodexSession(env: CostUsageTestEnvironment, fixture: SessionFixture) throws {
        try env.writeCodexSessionFile(
            day: fixture.day,
            filename: fixture.filename,
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": env.isoString(for: fixture.day),
                    "payload": ["session_id": fixture.sessionID],
                ],
                [
                    "type": "turn_context",
                    "timestamp": env.isoString(for: fixture.day),
                    "payload": ["model": fixture.model],
                ],
                [
                    "type": "event_msg",
                    "timestamp": env.isoString(for: fixture.day.addingTimeInterval(1)),
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "model": fixture.model,
                            "last_token_usage": [
                                "input_tokens": 100,
                                "cached_input_tokens": 10,
                                "output_tokens": 5,
                            ],
                        ],
                    ],
                ],
            ]))
    }

    private func lookup(
        snapshot: CostUsageTokenSnapshot,
        day: String,
        model: String) -> CostUsageDailyReport.ModelBreakdown?
    {
        snapshot.daily.first(where: { $0.date == day })?.modelBreakdowns?.first(where: { $0.modelName == model })
    }

    private func redactedProofRow(
        day: String,
        model: String,
        breakdown: CostUsageDailyReport.ModelBreakdown) -> [String: Any]
    {
        [
            "day": day,
            "model": model,
            "totalTokens": breakdown.totalTokens as Any,
            "costUSD": breakdown.costUSD as Any,
        ]
    }
}
