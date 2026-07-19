#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodePercentUnitLinuxTests {
    private func rollingPercent(used: Int, limit: Int) throws -> Double {
        let payload: [String: Any] = [
            "rollingUsage": ["used": used, "limit": limit, "resetInSec": 600],
            "weeklyUsage": ["used": used, "limit": limit, "resetInSec": 3600],
        ]
        let text = try String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? ""
        return try OpenCodeUsageFetcher.parseSubscription(text: text, now: Date(timeIntervalSince1970: 0))
            .rollingUsagePercent
    }

    @Test
    func `sub-one-percent computed usage is not rescaled to 100`() throws {
        // 1/100 = 1% used. The direct-fraction heuristic (<= 1 => * 100) must NOT touch a
        // computed used/limit percent, which is already 0...100 — else 1.0 becomes 100.
        #expect(try abs(self.rollingPercent(used: 1, limit: 100) - 1) < 0.0001)
        // 1/200 = 0.5% used (was wrongly rescaled to 50).
        #expect(try abs(self.rollingPercent(used: 1, limit: 200) - 0.5) < 0.0001)
    }

    @Test
    func `normal computed usage is unchanged`() throws {
        #expect(try abs(self.rollingPercent(used: 25, limit: 100) - 25) < 0.0001)
    }

    @Test
    func `direct fractional percent is still scaled to percent`() throws {
        // A direct percent field given as a 0...1 fraction keeps the existing behavior.
        let payload: [String: Any] = [
            "rollingUsage": ["usagePercent": 0.25, "resetInSec": 600],
            "weeklyUsage": ["usagePercent": 0.5, "resetInSec": 3600],
        ]
        let text = try String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? ""
        let snapshot = try OpenCodeUsageFetcher.parseSubscription(text: text, now: Date(timeIntervalSince1970: 0))
        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 50)
    }
}
#endif
