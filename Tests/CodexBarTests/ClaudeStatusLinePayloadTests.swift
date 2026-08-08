import Foundation
import Testing
@testable import CodexBarCore

/// The statusLine is the user's own configuration and Claude Code owns the schema, so every malformed shape
/// must read as absence. These cases are the fail-soft contract from the owner ruling on #2733.
struct ClaudeStatusLinePayloadTests {
    private func parse(
        _ json: String,
        now: Date = Date(timeIntervalSince1970: 1_000_000)) -> ClaudeStatusLineRateLimits?
    {
        ClaudeStatusLinePayloadParser.parse(Data(json.utf8), now: now)
    }

    private func envelope(_ payload: String, configDir: String = "/Users/x/.claude") -> String {
        """
        {"schema":1,"capturedAt":1000000,"configDir":"\(configDir)","payload":\(payload)}
        """
    }

    @Test
    func `reads both windows from a well formed payload`() throws {
        let limits = try #require(self.parse(self.envelope("""
        {"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1786099200},
        "seven_day":{"used_percentage":63,"resets_at":1786608000}}}
        """)))
        #expect(limits.fiveHour?.usedPercent == 42.5)
        #expect(limits.sevenDay?.usedPercent == 63)
        #expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_786_099_200))
        #expect(limits.configDir == "/Users/x/.claude")
    }

    @Test
    func `accepts utilization as a sibling spelling of used percentage`() throws {
        let limits = try #require(self.parse(self.envelope(
            #"{"rate_limits":{"five_hour":{"utilization":12}}}"#)))
        #expect(limits.fiveHour?.usedPercent == 12)
        #expect(limits.sevenDay == nil)
    }

    @Test
    func `accepts an ISO8601 reset timestamp`() throws {
        let limits = try #require(self.parse(self.envelope("""
        {"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":"2026-08-07T16:00:00Z"}}}
        """)))
        #expect(limits.fiveHour?.resetsAt != nil)
    }

    @Test
    func `a payload embedded as a string still parses`() throws {
        // The shim forwards Claude's stdin verbatim, which may arrive quoted.
        let embedded = #"{\"rate_limits\":{\"five_hour\":{\"used_percentage\":9}}}"#
        let limits = try #require(self.parse(#"{"schema":1,"capturedAt":1000000,"payload":"\#(embedded)"}"#))
        #expect(limits.fiveHour?.usedPercent == 9)
    }

    @Test
    func `malformed and drifted payloads read as absence rather than error`() {
        let cases: [(String, String)] = [
            ("not json at all", "not json at all"),
            ("unknown schema version", #"{"schema":99,"payload":{"rate_limits":{"five_hour":{"used_percentage":1}}}}"#),
            ("missing schema", #"{"payload":{"rate_limits":{"five_hour":{"used_percentage":1}}}}"#),
            ("no rate_limits key", self.envelope(#"{"something_else":{}}"#)),
            ("windows present but empty", self.envelope(#"{"rate_limits":{"five_hour":{}}}"#)),
            ("percentage is a string", self.envelope(#"{"rate_limits":{"five_hour":{"used_percentage":"42"}}}"#)),
            ("percentage is a bool", self.envelope(#"{"rate_limits":{"five_hour":{"used_percentage":true}}}"#)),
            ("percentage out of range", self.envelope(#"{"rate_limits":{"five_hour":{"used_percentage":250}}}"#)),
            ("negative percentage", self.envelope(#"{"rate_limits":{"five_hour":{"used_percentage":-3}}}"#)),
            ("rate_limits is an array", self.envelope(#"{"rate_limits":[]}"#)),
            ("empty object", "{}"),
        ]
        for (label, json) in cases {
            #expect(self.parse(json) == nil, "\(label) should read as absence")
        }
    }

    @Test
    func `an unparseable reset timestamp keeps the window and drops only the reset`() throws {
        let limits = try #require(self.parse(self.envelope("""
        {"rate_limits":{"five_hour":{"used_percentage":7,"resets_at":"whenever"}}}
        """)))
        #expect(limits.fiveHour?.usedPercent == 7)
        #expect(limits.fiveHour?.resetsAt == nil)
    }

    @Test
    func `an observation with no usable capture time is dropped`() {
        // Defaulting to "now" would make a file that has sat on disk for hours look perpetually fresh and
        // defeat the staleness bound, so an unaged observation is absence.
        let windows = #"{"rate_limits":{"five_hour":{"used_percentage":1}}}"#
        #expect(self.parse(#"{"schema":1,"payload":\#(windows)}"#) == nil)
        #expect(self.parse(#"{"schema":1,"capturedAt":"not a date","payload":\#(windows)}"#) == nil)
    }
}
