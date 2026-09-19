import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct GrokNativeOverflowTests: GrokLocalSessionScannerTestSupport {
    @Test(arguments: [false, true])
    func `overflowing derived totals preserve explicit totals and token classes`(_ hasExplicitTotal: Bool) throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = try self.localDate(day: 20, hour: 15)
        var usage: [String: Any] = ["inputTokens": Int.max, "outputTokens": 1, "costUsdTicks": 100]
        if hasExplicitTotal { usage["totalTokens"] = 7 }
        usage["modelUsage"] = ["grok-4.6-build": usage]
        try self.writeUpdates(
            [self.turn(timestamp: now, usage: usage)],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: now)
        let summary = try self.summarize(fixture: fixture, now: now)
        let expected: Int? = hasExplicitTotal ? 7 : nil
        #expect(summary.totalTokens == expected)
        #expect(summary.historyCoverageIsEstablished == hasExplicitTotal)
        let day = try #require(summary.daily.first)
        #expect(day.inputTokens == Int.max)
        #expect(day.outputTokens == 1)
        #expect(day.totalTokens == expected)
        #expect(day.modelBreakdowns.first?.totalTokens == expected)
        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: 7))
        #expect(snapshot.last30DaysTokens == expected)
        #expect(snapshot.sessionTokens == expected)
        #expect(snapshot.last30DaysCostUSD == 100 / GrokLocalSessionScanner.costUsdTicksPerUSD)
        #expect(snapshot.costProvenance == .vendorMetered)
    }

    @Test(arguments: [false, true])
    func `native bucket model and window sums keep overflow unknown after later turns`(_ separateDays: Bool) throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = try self.localDate(day: 20, hour: 15)
        let rows = [Int.max, 1, 5].enumerated().map { index, count in
            var usage: [String: Any] = [
                "inputTokens": count, "outputTokens": 2, "totalTokens": count,
                "cachedReadTokens": count, "cacheCreationTokens": count, "reasoningTokens": count,
                "costUsdTicks": 100,
            ]
            usage["modelUsage"] = ["grok-4.6-build": usage]
            let offset = separateDays ? Double(index - 2) * 86400 : 0
            return self.turn(timestamp: now.addingTimeInterval(offset), usage: usage)
        }
        try self.writeUpdates(
            rows,
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: now)
        for _ in 0..<2 {
            // The second scan consumes the parsed cache and must retain the same unknown totals.
            let summary = try self.summarize(fixture: fixture, now: now)
            #expect(summary.totalTokens == nil)
            #expect(!summary.historyCoverageIsEstablished)
            let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: 7))
            #expect(snapshot.last30DaysTokens == nil)
            #expect(snapshot.daily.count == (separateDays ? 3 : 1))
            #expect(snapshot.last30DaysRequests == 3)
            if !separateDays {
                let day = try #require(snapshot.daily.first)
                #expect(day.totalTokens == nil)
                #expect(day.inputTokens == nil)
                #expect(day.cacheReadTokens == nil)
                #expect(day.cacheCreationTokens == nil)
                #expect(day.reasoningTokens == nil)
                #expect(day.outputTokens == 6)
                #expect(day.modelBreakdowns?.first?.totalTokens == nil)
                #expect(day.modelBreakdowns?.first?.inputTokens == nil)
                #expect(day.modelBreakdowns?.first?.outputTokens == 6)
            }
        }
    }

    @Test(arguments: ["true", "1.5", "1e40", "9223372036854775808", "-1"])
    func `invalid native token numbers remain unknown without erasing valid fields`(_ literal: String) throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = try self.localDate(day: 20, hour: 15)
        let raw = """
        {"timestamp":\(Int(now.timeIntervalSince1970)),"params":{"update":{"sessionUpdate":"turn_completed",\
        "usage":{"inputTokens":\(literal),"outputTokens":2,"costUsdTicks":100,\
        "modelUsage":{"grok-4.6-build":{"inputTokens":\(literal),"outputTokens":2,"costUsdTicks":100}}}}}}
        """
        try self.writeUpdates(
            [],
            rawLines: [raw],
            to: fixture.session.appendingPathComponent("updates.jsonl"),
            modificationDate: now)
        let summary = try self.summarize(fixture: fixture, now: now)
        let day = try #require(summary.daily.first)
        #expect(summary.totalTokens == nil)
        #expect(!summary.historyCoverageIsEstablished)
        #expect(day.inputTokens == nil)
        #expect(day.outputTokens == 2)
        #expect(day.modelBreakdowns.first?.inputTokens == nil)
        #expect(day.modelBreakdowns.first?.outputTokens == 2)
        #expect(day.costUSD == 100 / GrokLocalSessionScanner.costUsdTicksPerUSD)
    }
}
