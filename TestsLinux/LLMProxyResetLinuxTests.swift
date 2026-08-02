#if os(Linux)
import CodexBarCore
import Foundation
import Testing

struct LLMProxyResetLinuxTests {
    // 2023-11-14T22:13:20Z — the snapshot time treated as "now".
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func nextReset(resetTimes: [String]) throws -> Date? {
        let groups = resetTimes
            .map { "{ \"remaining_percent\": 50, \"reset_time\": \"\($0)\" }" }
            .joined(separator: ", ")
        let json = "{ \"providers\": { \"p\": { \"quota_groups\": [ \(groups) ] } } }"
        return try LLMProxyUsageFetcher
            ._parseSnapshotForTesting(Data(json.utf8), updatedAt: Self.now)
            .nextResetAt
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try #require(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year, month: month, day: day, hour: 0, minute: 0, second: 0).date)
    }

    @Test
    func `next reset skips already-elapsed reset times`() throws {
        // A past reset (stale until the API refreshes) must not be chosen over the soonest upcoming one.
        let reset = try self.nextReset(resetTimes: [
            "2023-11-01T00:00:00Z", // past (before now)
            "2023-11-20T00:00:00Z", // soonest future
            "2023-12-25T00:00:00Z", // later future
        ])
        #expect(try abs(#require(reset).timeIntervalSince(self.date(2023, 11, 20))) < 0.001)
    }

    @Test
    func `all-past reset times yield no next reset`() throws {
        let reset = try self.nextReset(resetTimes: [
            "2023-11-01T00:00:00Z",
            "2023-10-15T00:00:00Z",
        ])
        #expect(reset == nil)
    }

    @Test
    func `future reset time is preserved`() throws {
        let reset = try self.nextReset(resetTimes: ["2023-11-20T00:00:00Z"])
        #expect(try abs(#require(reset).timeIntervalSince(self.date(2023, 11, 20))) < 0.001)
    }
}
#endif
