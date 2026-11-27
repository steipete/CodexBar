import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct QuotaMenuTests {
    private let reset = "2026-11-27T00:00:00Z"

    @Test
    func `menu uses one direction for the label and gauge across all three cards`() throws {
        let codex = try CodexQuota.windows(Data("""
        {"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":1795737600}}}
        """.utf8))
        let kimi = try KimiQuota.windows(Data("""
        {"usage":{"limit":"20","remaining":"15","reset_time":"\(self.reset)"},
         "usages":{"limit_5h":{"used_ratio":0.25,"reset_time":"\(self.reset)"}}}
        """.utf8))
        let google = try AntigravityQuota.summary(Data("""
        {"response":{"groups":[{"name":"Gemini","buckets":[{"id":"weekly","remaining":{"case":"remainingFraction",
         "value":0.75},"resetTime":"\(self.reset)"}]}]}}
        """.utf8))
        #expect(Subscription.allCases.map(\.rawValue) == ["codex", "kimi", "antigravity"])
        #expect(kimi.map(\.title) == ["5 小时", "每周"])
        #expect(google.map(\.title) == ["Gemini · weekly"])
        #expect(codex.map(\.title) == ["Codex · 5 小时"])
        for window in codex + kimi + google {
            let used = QuotaMenuRow(window, showUsed: true)
            let left = QuotaMenuRow(window, showUsed: false)
            #expect(used.label == "25% 已用")
            #expect(used.fill == 25)
            #expect(left.label == "75% 剩余")
            #expect(left.fill == 75)
            #expect(used.resetsAt == ISO8601DateParser.parse(self.reset))
            #expect(left.resetsAt == used.resetsAt)
        }
    }

    @Test
    func `fresh display defaults to used and upgrades honor an explicit false`() {
        let defaults = MemoryDefaults()
        #expect(QuotaDisplayPreference.showUsed(in: defaults, defaultValue: true))
        defaults.values["usageBarsShowUsed"] = false
        defaults.values["providerOrder"] = ["claude", "kimi"]
        #expect(!QuotaDisplayPreference.showUsed(in: defaults, defaultValue: true))
        #expect(Subscription.allCases.count == 3)
        #expect(Subscription(rawValue: "claude") == nil)
    }

    @Test
    func `missing readings never become zero and optional malformed month is isolated`() throws {
        let data = Data("""
        {"usage":{"limit":"100"},"usages":{"limit_month_total":{"used_ratio":"unknown"},"limit_7d":{"used_ratio":0}},
         "limits":[{"window":{"duration":2,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":50,"used":30}},
                   {"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":20,"remaining":0}}]}
        """.utf8)
        let rows = try KimiQuota.windows(data)
        #expect(rows.map(\.usedPercent) == [100, 0])
        #expect(rows.map(\.title) == ["5 小时", "每周"])
        #expect(try KimiQuota.windows(Data(#"{"usage":{"limit":5}}"#.utf8)).isEmpty)
        let google = Data(#"{"groups":[{"buckets":[{"id":"unknown"},{"id":"empty","remainingFraction":0}]}]}"#.utf8)
        #expect(try AntigravityQuota.summary(google).map(\.usedPercent) == [100])
        let codex = Data(#"{"rate_limit":{"primary_window":{"reset_at":1},"secondary_window":{"used_percent":0}}}"#
            .utf8)
        #expect(try CodexQuota.windows(codex).map(\.usedPercent) == [0])
    }

    @Test
    func `matched Kimi reset uses exhausted counter and monthly comes only from the same reply`() throws {
        let data = Data("""
        {"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},
         "detail":{"limit":"10","used":"10","resetTime":"2026-11-27T00:00:01Z"}}],
         "usages":{"limit_5h":{"used_ratio":0,"reset_time":"\(self.reset)"}, "limit_month_total":{"used_ratio":0.12}}}
        """.utf8)
        #expect(try KimiQuota.windows(data).map(\.usedPercent) == [100, 12])
    }
}

private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { self.values[key] }
}
