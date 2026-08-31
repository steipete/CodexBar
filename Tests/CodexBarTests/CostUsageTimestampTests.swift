import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageTimestampTests {
    private static func historicalDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    @Test
    func `native timestamps preserve exact formatter precision`() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        for year in [1900, 1960, 1969, 1970, 2000, 2024, 2026, 2100, 2400, 9999] {
            for day in ["01-01", "02-28", "03-01", "12-31"] {
                for time in ["00:00:00", "12:34:56", "23:59:59"] {
                    for fraction in ["", ".0", ".1", ".01", ".123", ".999", ".123456", ".999999999"] {
                        for zone in ["Z", "+00:00", "-00:00", "+05:30", "-08:00"] {
                            let text = "\(year)-\(day)T\(time)\(fraction)\(zone)"
                            let expected = fractional.date(from: text) ?? plain.date(from: text)
                            #expect(CostUsageScanner.dateFromTimestamp(text) == expected, "\(text)")
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [
        "2024-02-29T23:59:59.999Z", "2000-02-29T12:00:00Z",
        "2026-08-30T12:34:56+0530", "2026-08-30T12:34:56+05",
        "2026-08-30T12:34:56.123456789012Z", "2026-08-30T12:34:56.1234567890Z",
        "1582-10-04T12:34:56Z", "0001-01-01T00:00:00Z",
        "2026-08-30T12:34:56+23:59", "2026-08-30T12:34:56Ztrailing",
        "2026-02-30T12:34:56Z", "1900-02-29T12:00:00Z",
        "2026-08-30T24:00:00Z", "2016-12-31T23:59:60Z",
        "", "2026-08-30", "not-a-date", "2026-08-30t12:34:56z",
        "2026-13-01T00:00:00Z", "2026-08-30T12:34:56.Z",
        "2026-08-30T12:34:56.123", "2026-08-30T12:34:56+25:00",
        "2026-08-30T12:34:56+05:99", "2026-08-30T12:34:56.١Z",
    ])
    func `historical spellings and invalid inputs retain formatter behavior`(_ text: String) {
        #expect(CostUsageScanner.dateFromTimestamp(text) == Self.historicalDate(text))
    }

    @Test(arguments: ["America/Los_Angeles", "Asia/Kolkata", "Pacific/Kiritimati", "UTC"])
    func `Claude reuses parsed date without changing local days`(_ timeZone: String) throws {
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = try #require(TimeZone(identifier: timeZone))
        for text in [
            "2026-03-08T09:59:59.999999Z", "2026-03-08T10:00:00.000Z",
            "2026-11-01T08:59:59.999999Z", "2026-11-01T09:00:00Z",
            "2026-08-30T23:59:59.999999999-08:00", "2024-02-29T23:59:59.999+05:30",
            "1969-12-31T23:59:59.999999Z", "2026-08-30T12:34:56+0530",
            "2026-02-30T12:00:00Z", "2016-12-31T23:59:60Z",
        ] {
            guard let expectedDate = Self.historicalDate(text) else {
                #expect(CostUsageScanner.claudeTimestampAndDayKey(text, calendar: calendar) == nil)
                continue
            }
            let expectedDay = CostUsageScanner.dayKeyFromTimestamp(text, calendar: calendar)
                ?? CostUsageScanner.CostUsageDayRange.dayKey(from: expectedDate, calendar: calendar)
            let actual = try #require(CostUsageScanner.claudeTimestampAndDayKey(text, calendar: calendar))
            #expect(actual.date == expectedDate)
            #expect(actual.dayKey == expectedDay)
        }
    }

    @Test
    func `Claude ingestion preserves tokens days deduplication and dated pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let timestamps = [
            "2026-03-08T09:59:59.999999Z", "2026-03-08T10:00:00Z",
            "2026-03-12T23:59:59.999999Z", "2026-03-13T00:00:00.000Z",
            "2026-03-13T00:00:00+0530", "2026-03-13T23:59:59.999-08:00",
        ]
        let model = "claude-sonnet-4-6"
        let lines = timestamps.enumerated().map { index, timestamp in
            [
                "type": "assistant", "timestamp": timestamp, "requestId": "request-\(index)",
                "message": [
                    "id": "message-\(index)", "model": model,
                    "usage": [
                        "input_tokens": 210_000, "output_tokens": 20,
                        "cache_creation_input_tokens": 50, "cache_read_input_tokens": 25,
                    ],
                ],
            ] as [String: Any]
        }
        let contents = try env.jsonl(lines + lines)
        let file = try env.writeClaudeProjectFile(
            relativePath: "synthetic/session.jsonl", contents: contents)
        let range = try CostUsageScanner.CostUsageDayRange(
            since: #require(Self.historicalDate("2026-03-01T00:00:00Z")),
            until: #require(Self.historicalDate("2026-03-31T00:00:00Z")),
            calendar: calendar)
        let parsed = try CostUsageScanner.parseClaudeFileCancellable(
            fileURL: file,
            range: range,
            providerFilter: .all,
            pricingResolver: CostUsagePricing.ClaudeResolver(now: Date(), cacheRoot: env.cacheRoot))
        #expect(parsed.rows.count == timestamps.count)
        var expectedDays: [String: [String: [Int]]] = [:]
        for (index, text) in timestamps.enumerated() {
            let date = try #require(Self.historicalDate(text))
            let day = try #require(CostUsageScanner.dayKeyFromTimestamp(text, calendar: calendar))
            let cost = try #require(CostUsagePricing.claudeCostUSD(
                model: model,
                inputTokens: 210_000,
                cacheReadInputTokens: 25,
                cacheCreationInputTokens: 50,
                outputTokens: 20,
                pricingDate: date,
                modelsDevCacheRoot: env.cacheRoot))
            let nanos = Int((cost * 1_000_000_000).rounded())
            let row = try #require(parsed.rows.first { $0.messageId == "message-\(index)" })
            #expect(row.timestampUnixMs == Int64((date.timeIntervalSince1970 * 1000).rounded()))
            #expect(row.dayKey == day)
            #expect(row.costNanos == nanos)
            let packed = [210_000, 25, 50, 20, nanos, 1, 1, 0]
            var total = expectedDays[day]?[model] ?? Array(repeating: 0, count: packed.count)
            for slot in packed.indices {
                total[slot] += packed[slot]
            }
            expectedDays[day] = [model: total]
        }
        #expect(parsed.days == expectedDays)
        #expect(parsed.parsedBytes == Int64(Data(contents.utf8).count))
    }
}
