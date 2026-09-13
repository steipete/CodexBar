import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityNativeUsageTests {
    private func payload(fraction: Double = 0.46, turns: Int = 0) -> Data {
        Data("""
        {"status":"SUCCESS","num_turns":\(turns),"usage":{"total_tokens":0},
        "command":{"name":"usage","data":{"groups":[{"name":"Gemini Models",
        "buckets":[{"id":"gemini-5h","name":"Five Hour Limit Remaining",
        "remaining_fraction":\(fraction),"reset_time":"2026-09-14T01:00:00Z"}]}]}}}
        """.utf8)
    }

    @Test func `remaining quota is converted to used percent and keeps reset`() throws {
        let snapshot = try AntigravityNativeUsage.parse(self.payload())
        let bucket = try #require(snapshot.quotaSummary?.groups.first?.buckets.first)
        #expect(bucket.remainingFraction == 0.46)
        #expect(bucket.resetTime != nil)
        #expect(snapshot.accountEmail == nil)
        let usage = try snapshot.toUsageSnapshot()
        #expect(try abs(#require(usage.primary).usedPercent - 54) < 0.001)
    }

    @Test func `invalid percentages and model turns are rejected`() {
        #expect(throws: (any Error).self) { try AntigravityNativeUsage.parse(self.payload(fraction: 2)) }
        #expect(throws: (any Error).self) { try AntigravityNativeUsage.parse(self.payload(turns: 1)) }
        #expect(throws: (any Error).self) { try AntigravityNativeUsage.parse(Data("{}".utf8)) }
        let blankID = String(decoding: self.payload(), as: UTF8.self)
            .replacingOccurrences(of: "gemini-5h", with: " ")
        #expect(throws: (any Error).self) { try AntigravityNativeUsage.parse(Data(blankID.utf8)) }
    }
}
