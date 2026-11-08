import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxUsageSummaryTests {
    private let now = ISO8601DateFormatter().date(from: "2026-07-08T04:00:00Z")!

    @Test
    func `decodes authentication errors before malformed daily data`() {
        let data = Data(#"{"base_resp":{"status_code":"1004","status_msg":"not login"},"date_model_usage":false}"#.utf8)
        #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try MiniMaxUsageSummaryParser.parse(data: data, now: self.now)
        }
    }

    @Test
    func `does not require daily arrays to recognize API errors`() {
        let data = Data(#"{"base_resp":{"status_code":5000,"status_msg":"unavailable"}}"#.utf8)
        #expect(throws: MiniMaxUsageError.apiError("status_code 5000")) {
            try MiniMaxUsageSummaryParser.parse(data: data, now: self.now)
        }
    }

    @Test
    func `keeps exact integer and numeric string counts without adding cache subsets`() throws {
        let summary = try self.parse(#"""
        [{"date":"2026-07-08","total_token":"1100","total_input_token":1000,
          "total_output_token":"100","total_cache_read_token":"800","total_cache_create_token":50}]
        """#)
        let day = try #require(summary.today(now: self.now))
        #expect(day.totalTokens == 1100)
        #expect(day.inputTokens == 1000)
        #expect(day.outputTokens == 100)
        #expect(day.cacheReadTokens == 800)
        #expect(day.cacheWriteTokens == 50)
        #expect(summary.last30DaysTokens(now: self.now) == 1100)
        let rows = try #require(summary.detailSection(now: self.now)).rows
        #expect(rows.first { $0.label == "Cache read tokens" }?.secondaryValue == "Included in input tokens")
        #expect(rows.first { $0.label == "Cache write tokens" }?.secondaryValue == nil)
    }

    @Test
    func `ignores invalid counts without discarding valid fields or days`() throws {
        let summary = try self.parse(#"""
        [null, 12, {"date":true},
         {"date":"2026-07-08","total_token":"9223372036854775808","total_input_token":-1,
          "total_output_token":"9.5","total_cache_read_token":null,"total_cache_create_token":0},
         {"date":"2026-07-07","total_token":42}]
        """#)
        let day = try #require(summary.today(now: self.now))
        #expect(day.totalTokens == nil)
        #expect(day.inputTokens == nil)
        #expect(day.outputTokens == nil)
        #expect(day.cacheReadTokens == nil)
        #expect(day.cacheWriteTokens == 0)
        #expect(summary.days.count == 2)
        #expect(summary.last30DaysTokens(now: self.now) == nil)
    }

    @Test
    func `preserves counts above double precision and rejects aggregate overflow`() throws {
        let summary = try self.parse(#"""
        [{"date":"2026-07-08","total_token":"9223372036854775807"},
         {"date":"2026-07-07","total_token":1}]
        """#)
        #expect(summary.today(now: self.now)?.totalTokens == Int.max)
        #expect(summary.last30DaysTokens(now: self.now) == nil)
        #expect(summary.detailSection(now: self.now)?.chart?.points.count == 2)
    }

    @Test
    func `does not derive missing totals from input and output`() throws {
        let summary = try self.parse(#"""
        [{"date":"2026-07-08","total_input_token":10,"total_output_token":5,
          "total_cache_read_token":8}]
        """#)
        let section = try #require(summary.detailSection(now: self.now))
        #expect(summary.today(now: self.now)?.totalTokens == nil)
        #expect(summary.last30DaysTokens(now: self.now) == nil)
        #expect(section.rows.first?.value == "—")
        #expect(section.chart == nil)
    }

    @Test
    func `preserves known zero usage`() throws {
        let summary = try self.parse(#"""
        [{"date":"2026-07-08","total_token":0,"total_input_token":0,"total_output_token":0,
          "total_cache_read_token":0,"total_cache_create_token":0}]
        """#)
        let section = try #require(summary.detailSection(now: self.now))
        #expect(summary.last30DaysTokens(now: self.now) == 0)
        #expect(section.rows.first?.value == 0.formatted())
        #expect(section.chart?.points.first?.value == 0)
    }

    @Test
    func `does not treat the latest reported day or update time as today`() throws {
        let summary = try self.parse(
            #"[{"date":"2026-07-07","total_token":17}]"#,
            updateTime: "07-08 10:30")
        let section = try #require(summary.detailSection(now: self.now))
        #expect(summary.today(now: self.now) == nil)
        #expect(summary.last30DaysTokens(now: self.now) == 17)
        #expect(section.rows.first?.value == "—")
        #expect(section.rows.last?.label == "Data updated")
        #expect(section.rows.last?.value == "07-08 10:30")
    }

    @Test
    func `uses China dates across the UTC and local calendar boundary`() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-07T17:00:00Z"))
        let summary = try self.parse(
            #"[{"date":"2026-07-07","total_token":7},{"date":"2026-07-08","total_token":8}]"#,
            now: now)
        #expect(summary.today(now: now)?.totalTokens == 8)
    }

    @Test
    func `sorts valid days and uses calendar dates for the thirty day window`() throws {
        let summary = try self.parse(#"""
        [{"date":"2026-07-08","total_token":8},
         {"date":"2026-06-09","total_token":9},
         {"date":"2026-06-08","total_token":100},
         {"date":"2026-07-09","total_token":1000},
         {"date":"2026-02-30","total_token":10000}]
        """#)
        #expect(summary.days.map(\.date) == ["2026-06-08", "2026-06-09", "2026-07-08"])
        #expect(summary.last30DaysTokens(now: self.now) == 17)
        #expect(summary.detailSection(now: self.now)?.chart?.points.map(\.label) == ["2026-06-09", "2026-07-08"])
    }

    @Test(arguments: ["2026-+7-08", "2026-07-+8", "2026-7-08", "2026-02-30"])
    func `rejects noncanonical and nonexistent dates`(_ date: String) throws {
        let summary = try self.parse(#"[{"date":"\#(date)","total_token":100}]"#)
        #expect(summary.days.isEmpty)
        #expect(summary.detailSection(now: self.now) == nil)
    }

    @Test
    func `does not reconstruct dated history from undated totals`() throws {
        let data = Data(#"""
        {"base_resp":{"status_code":0},"daily_token_usage":[1,2,3],
         "total_token_consumed":"1.2B","last_update_time":"07-08 12:00"}
        """#.utf8)
        let summary = try MiniMaxUsageSummaryParser.parse(data: data, now: self.now)
        #expect(summary.days.isEmpty)
        #expect(summary.last30DaysTokens(now: self.now) == nil)
        #expect(summary.detailSection(now: self.now) == nil)
    }

    @Test
    func `deduplicates identical records and preserves unknown totals for conflicting dates`() throws {
        let summary = try self.parse(#"""
        [{"date":"2026-07-08","total_token":8},{"date":"2026-07-08","total_token":8},
         {"date":"2026-07-07","total_token":7},{"date":"2026-07-07","total_token":70}]
        """#)
        #expect(summary.days.count == 2)
        #expect(summary.today(now: self.now)?.totalTokens == 8)
        #expect(summary.days.first { $0.date == "2026-07-07" }?.totalTokens == nil)
        #expect(summary.last30DaysTokens(now: self.now) == nil)
    }

    @Test
    func `preserves dated records with missing counts instead of understating period totals`() throws {
        let summary = try self.parse(#"""
        [{"date":"2026-07-08","total_token":8},
         {"date":"2026-07-07","total_token":null}]
        """#)
        #expect(summary.days.count == 2)
        #expect(summary.last30DaysTokens(now: self.now) == nil)
        let section = try #require(summary.detailSection(now: self.now))
        #expect(section.rows.first { $0.label == "30d tokens" }?.value == "—")
        #expect(section.chart?.points.count == 1)
    }

    @Test(arguments: [#"{}"#, #"{"date_model_usage":null}"#, #"{"date_model_usage":[]}"#])
    func `omits empty summaries`(_ payload: String) throws {
        let summary = try MiniMaxUsageSummaryParser.parse(data: Data(payload.utf8), now: self.now)
        #expect(summary.detailSection(now: self.now) == nil)
    }

    @Test
    func `reports incompatible daily schema for optional fetch fallback`() {
        let data = Data(#"{"base_resp":{"status_code":0},"date_model_usage":"changed"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try MiniMaxUsageSummaryParser.parse(data: data, now: self.now)
        }
    }

    private func parse(
        _ days: String,
        updateTime: String = "07-08 12:00",
        now: Date? = nil) throws -> MiniMaxUsageSummary
    {
        let data = Data("""
        {"base_resp":{"status_code":0},"date_model_usage":\(days),"last_update_time":"\(updateTime)"}
        """.utf8)
        return try MiniMaxUsageSummaryParser.parse(data: data, now: now ?? self.now)
    }
}
