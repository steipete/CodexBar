import Foundation
import Testing
@testable import CodexBarCore

struct AdminAPIUsageLocalDaySelectionTests {
    @Test
    func `OpenAI current day includes UTC bucket containing positive timezone morning`() throws {
        let calendar = try Self.calendar(timeZoneIdentifier: "Australia/Sydney")
        let now = try Self.date(year: 2026, month: 5, day: 18, hour: 8, timeZoneIdentifier: "Australia/Sydney")
        let staleUTCStart = try Self.date(year: 2026, month: 5, day: 16, hour: 0, timeZoneIdentifier: "UTC")
        let overlappingUTCStart = try Self.date(year: 2026, month: 5, day: 17, hour: 0, timeZoneIdentifier: "UTC")
        let usage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2026-05-16",
                    startTime: staleUTCStart,
                    endTime: staleUTCStart.addingTimeInterval(86400),
                    costUSD: 9,
                    requests: 9,
                    inputTokens: 900,
                    cachedInputTokens: 90,
                    outputTokens: 90,
                    totalTokens: 990,
                    lineItems: [],
                    models: []),
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2026-05-17",
                    startTime: overlappingUTCStart,
                    endTime: overlappingUTCStart.addingTimeInterval(86400),
                    costUSD: 2.5,
                    requests: 3,
                    inputTokens: 200,
                    cachedInputTokens: 20,
                    outputTokens: 30,
                    totalTokens: 250,
                    lineItems: [],
                    models: []),
            ],
            updatedAt: now)

        let today = usage.summary(forLocalDayContaining: now, calendar: calendar)

        #expect(today.costUSD == 2.5)
        #expect(today.requests == 3)
        #expect(today.totalTokens == 250)
    }

    @Test
    func `OpenAI current day does not sum adjacent UTC buckets after positive timezone UTC rollover`() throws {
        let calendar = try Self.calendar(timeZoneIdentifier: "Australia/Sydney")
        let now = try Self.date(year: 2026, month: 5, day: 18, hour: 16, timeZoneIdentifier: "Australia/Sydney")
        let previousUTCStart = try Self.date(year: 2026, month: 5, day: 17, hour: 0, timeZoneIdentifier: "UTC")
        let currentUTCStart = try Self.date(year: 2026, month: 5, day: 18, hour: 0, timeZoneIdentifier: "UTC")
        let usage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2026-05-17",
                    startTime: previousUTCStart,
                    endTime: previousUTCStart.addingTimeInterval(86400),
                    costUSD: 2.5,
                    requests: 3,
                    inputTokens: 200,
                    cachedInputTokens: 20,
                    outputTokens: 30,
                    totalTokens: 250,
                    lineItems: [],
                    models: []),
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2026-05-18",
                    startTime: currentUTCStart,
                    endTime: currentUTCStart.addingTimeInterval(86400),
                    costUSD: 4.5,
                    requests: 5,
                    inputTokens: 400,
                    cachedInputTokens: 40,
                    outputTokens: 50,
                    totalTokens: 490,
                    lineItems: [],
                    models: []),
            ],
            updatedAt: now)

        let today = usage.summary(forLocalDayContaining: now, calendar: calendar)

        #expect(today.costUSD == 4.5)
        #expect(today.requests == 5)
        #expect(today.totalTokens == 490)
    }

    @Test
    func `Claude Admin current day includes UTC bucket containing positive timezone morning`() throws {
        let calendar = try Self.calendar(timeZoneIdentifier: "Australia/Sydney")
        let now = try Self.date(year: 2026, month: 5, day: 18, hour: 8, timeZoneIdentifier: "Australia/Sydney")
        let staleUTCStart = try Self.date(year: 2026, month: 5, day: 16, hour: 0, timeZoneIdentifier: "UTC")
        let overlappingUTCStart = try Self.date(year: 2026, month: 5, day: 17, hour: 0, timeZoneIdentifier: "UTC")
        let usage = ClaudeAdminAPIUsageSnapshot(
            daily: [
                ClaudeAdminAPIUsageSnapshot.DailyBucket(
                    day: "2026-05-16",
                    startTime: staleUTCStart,
                    endTime: staleUTCStart.addingTimeInterval(86400),
                    costUSD: 9,
                    inputTokens: 900,
                    cacheCreationInputTokens: 90,
                    cacheReadInputTokens: 45,
                    outputTokens: 90,
                    totalTokens: 1125,
                    costItems: [],
                    models: []),
                ClaudeAdminAPIUsageSnapshot.DailyBucket(
                    day: "2026-05-17",
                    startTime: overlappingUTCStart,
                    endTime: overlappingUTCStart.addingTimeInterval(86400),
                    costUSD: 2.5,
                    inputTokens: 200,
                    cacheCreationInputTokens: 20,
                    cacheReadInputTokens: 10,
                    outputTokens: 30,
                    totalTokens: 260,
                    costItems: [],
                    models: []),
            ],
            updatedAt: now)

        let today = usage.summary(forLocalDayContaining: now, calendar: calendar)

        #expect(today.costUSD == 2.5)
        #expect(today.inputTokens == 200)
        #expect(today.totalTokens == 260)
    }

    @Test
    func `Claude Admin current day does not sum adjacent UTC buckets after negative timezone UTC rollover`() throws {
        let calendar = try Self.calendar(timeZoneIdentifier: "America/Los_Angeles")
        let now = try Self.date(year: 2026, month: 6, day: 22, hour: 20, timeZoneIdentifier: "America/Los_Angeles")
        let previousUTCStart = try Self.date(year: 2026, month: 6, day: 22, hour: 0, timeZoneIdentifier: "UTC")
        let currentUTCStart = try Self.date(year: 2026, month: 6, day: 23, hour: 0, timeZoneIdentifier: "UTC")
        let usage = ClaudeAdminAPIUsageSnapshot(
            daily: [
                ClaudeAdminAPIUsageSnapshot.DailyBucket(
                    day: "2026-06-22",
                    startTime: previousUTCStart,
                    endTime: previousUTCStart.addingTimeInterval(86400),
                    costUSD: 2.5,
                    inputTokens: 200,
                    cacheCreationInputTokens: 20,
                    cacheReadInputTokens: 10,
                    outputTokens: 30,
                    totalTokens: 260,
                    costItems: [],
                    models: []),
                ClaudeAdminAPIUsageSnapshot.DailyBucket(
                    day: "2026-06-23",
                    startTime: currentUTCStart,
                    endTime: currentUTCStart.addingTimeInterval(86400),
                    costUSD: 4.5,
                    inputTokens: 400,
                    cacheCreationInputTokens: 40,
                    cacheReadInputTokens: 20,
                    outputTokens: 50,
                    totalTokens: 510,
                    costItems: [],
                    models: []),
            ],
            updatedAt: now)

        let today = usage.summary(forLocalDayContaining: now, calendar: calendar)

        #expect(today.costUSD == 4.5)
        #expect(today.inputTokens == 400)
        #expect(today.totalTokens == 510)
    }

    private static func calendar(timeZoneIdentifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timeZoneIdentifier))
        return calendar
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        timeZoneIdentifier: String) throws -> Date
    {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: timeZoneIdentifier)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return try #require(components.date)
    }
}
