#if os(macOS)

import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct OpenCodeGoLocalUsageReaderTests {
    @Test
    func `reads local OpenCode Go history into usage windows`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 3.0)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-05T12:00:00.000Z"),
            cost: 6.0)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-02-25T07:53:16.000Z"),
            cost: 2.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 30)
        #expect(snapshot.monthlyUsagePercent == 18.3)
        #expect(snapshot.rollingResetInSec == 14400)
        #expect(snapshot.weeklyResetInSec == 216_000)
        #expect(snapshot.monthlyResetInSec == 1_626_796)
    }

    @Test
    func `reads idle WAL database without creating sidecars`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 3.0)
        try Self.configureIdleWAL(at: env.databaseURL)

        let walURL = URL(fileURLWithPath: env.databaseURL.path + "-wal")
        let sharedMemoryURL = URL(fileURLWithPath: env.databaseURL.path + "-shm")
        #expect(!FileManager.default.fileExists(atPath: walURL.path))
        #expect(!FileManager.default.fileExists(atPath: sharedMemoryURL.path))

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(!FileManager.default.fileExists(atPath: walURL.path))
        #expect(!FileManager.default.fileExists(atPath: sharedMemoryURL.path))
    }

    @Test
    func `builds daily cost history buckets within the requested window`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        // Fixed UTC hours can straddle local midnight, for example in Sydney.
        let reference = Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-03-06T15:00:00.000Z")) / 1000)
        let currentDay = Calendar.current.startOfDay(for: reference)
        let previousDay = try #require(Calendar.current.date(byAdding: .day, value: -1, to: currentDay))
        let now = currentDay.addingTimeInterval(12 * 3600)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(currentDay.addingTimeInterval(3600)),
            cost: 3.0)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(currentDay.addingTimeInterval(2 * 3600)),
            cost: 1.5)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(previousDay.addingTimeInterval(3600)),
            cost: 6.0)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-01-01T12:00:00.000Z"),
            cost: 100.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: now, historyDays: 30)

        let previousDayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: previousDay)
        let currentDayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: currentDay)
        #expect(snapshot.daily.map(\.date) == [previousDayKey, currentDayKey])
        #expect(snapshot.daily.first?.costUSD == 6.0)
        #expect(snapshot.daily.first?.requestCount == 1)
        #expect(snapshot.daily.last?.costUSD == 4.5)
        #expect(snapshot.daily.last?.requestCount == 2)
    }

    @Test
    func `auth without history falls through to web strategy`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)

        #expect(throws: OpenCodeGoLocalUsageError.historyUnavailable("database not found")) {
            _ = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))
        }
    }

    @Test
    func `auth with unreadable history falls through to web strategy`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        var db: OpaquePointer?
        guard sqlite3_open(env.databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        sqlite3_close(db)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)

        #expect(throws: OpenCodeGoLocalUsageError.self) {
            _ = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))
        }
    }

    @Test
    func `monthly window keeps original anchor after shorter month clamp`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-01-31T00:00:00.000Z"),
            cost: 1.0)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-29T10:00:00.000Z"),
            cost: 6.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let now = Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-03-29T12:00:00.000Z")) / 1000)
        let snapshot = try reader.fetch(now: now)

        #expect(snapshot.monthlyUsagePercent == 10)
        #expect(snapshot.monthlyResetInSec == 129_600)
    }

    @Test
    func `reads step finish parts when message only stores metadata`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        let messageID = try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: nil)
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 3.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 10)
        #expect(snapshot.monthlyUsagePercent == 5)
    }

    @Test
    func `uses message cost while counting step finish requests`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        let messageID = try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 3.0)
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 1.0)
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms("2026-03-06T11:05:00.000Z"),
            cost: 2.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        #expect(snapshot.rollingUsagePercent == 25)
        #expect(snapshot.weeklyUsagePercent == 10)
        #expect(snapshot.monthlyUsagePercent == 5)
        #expect(snapshot.daily.first?.costUSD == 3.0)
        #expect(snapshot.daily.first?.requestCount == 2)
    }

    @Test
    func `daily request count buckets step finish parts by their timestamps`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        let anchor = Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-03-06T15:00:00.000Z")) / 1000)
        let dayStart = Calendar.current.startOfDay(for: anchor)
        let now = dayStart.addingTimeInterval(6 * 60 * 60)
        let beforeMidnight = dayStart.addingTimeInterval(-60)
        let afterMidnight = dayStart.addingTimeInterval(60)
        // One assistant turn can make provider requests on opposite sides of local midnight.
        let messageID = try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(beforeMidnight),
            cost: nil)
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms(beforeMidnight),
            cost: 1.0)
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms(afterMidnight),
            cost: 2.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: now, historyDays: 30)

        #expect(snapshot.daily.count == 2)
        #expect(snapshot.daily.first?.costUSD == 1.0)
        #expect(snapshot.daily.first?.requestCount == 1)
        #expect(snapshot.daily.last?.costUSD == 2.0)
        #expect(snapshot.daily.last?.requestCount == 1)
    }

    @Test
    func `daily entries group cost by model within a day`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        let reference = Date(timeIntervalSince1970: TimeInterval(Self.ms("2026-03-06T15:00:00.000Z")) / 1000)
        let day = Calendar.current.startOfDay(for: reference)
        let now = day.addingTimeInterval(12 * 3600)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(day.addingTimeInterval(3600)),
            cost: 3.0,
            model: "claude-sonnet-4-5")
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(day.addingTimeInterval(2 * 3600)),
            cost: 2.0,
            model: "gpt-5.1-codex")
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(day.addingTimeInterval(3 * 3600)),
            cost: 1.0,
            model: "claude-sonnet-4-5")

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: now, historyDays: 30)

        #expect(snapshot.daily.count == 1)
        let entry = try #require(snapshot.daily.first)
        #expect(entry.costUSD == 6.0)
        #expect(entry.requestCount == 3)
        #expect(entry.modelsUsed == ["claude-sonnet-4-5", "gpt-5.1-codex"])

        let breakdowns = try #require(entry.modelBreakdowns)
        #expect(breakdowns.count == 2)
        #expect(breakdowns.first?.modelName == "claude-sonnet-4-5")
        #expect(breakdowns.first?.costUSD == 4.0)
        #expect(breakdowns.first?.requestCount == 2)
        #expect(breakdowns.last?.modelName == "gpt-5.1-codex")
        #expect(breakdowns.last?.costUSD == 2.0)
        #expect(breakdowns.last?.requestCount == 1)
    }

    @Test
    func `step finish parts inherit their model from the parent message`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        let messageID = try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: nil,
            model: "grok-code-fast-1")
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 3.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        let entry = try #require(snapshot.daily.first)
        #expect(entry.modelsUsed == ["grok-code-fast-1"])
        #expect(entry.modelBreakdowns?.first?.modelName == "grok-code-fast-1")
        #expect(entry.modelBreakdowns?.first?.costUSD == 3.0)
    }

    @Test
    func `messages without a model fall back to the unknown model bucket`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 4.0)

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        let entry = try #require(snapshot.daily.first)
        #expect(entry.costUSD == 4.0)
        #expect(entry.modelsUsed == ["unknown"])
        #expect(entry.modelBreakdowns?.first?.modelName == "unknown")
        #expect(entry.modelBreakdowns?.first?.costUSD == 4.0)
    }

    @Test
    func `whitespace only model ids fall back to the unknown model bucket`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms("2026-03-06T11:00:00.000Z"),
            cost: 5.0,
            model: "   ")

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))

        let entry = try #require(snapshot.daily.first)
        #expect(entry.modelsUsed == ["unknown"])
        #expect(entry.modelBreakdowns?.first?.modelName == "unknown")
        #expect(entry.modelBreakdowns?.first?.costUSD == 5.0)
    }

    @Test
    func `model ids with incidental whitespace merge with the trimmed model bucket`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let reference = Date(timeIntervalSince1970: 1_772_798_400)
        let now = Calendar.current.startOfDay(for: reference).addingTimeInterval(12 * 3600)

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(now.addingTimeInterval(-3600)),
            cost: 2.0,
            model: "claude-sonnet-4-5")
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(now.addingTimeInterval(-1800)),
            cost: 3.0,
            model: "  claude-sonnet-4-5  ")

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: now, historyDays: 30)

        let entry = try #require(snapshot.daily.first)
        #expect(entry.modelsUsed == ["claude-sonnet-4-5"])
        let breakdowns = try #require(entry.modelBreakdowns)
        #expect(breakdowns.count == 1)
        #expect(breakdowns.first?.modelName == "claude-sonnet-4-5")
        #expect(breakdowns.first?.costUSD == 5.0)
        #expect(breakdowns.first?.requestCount == 2)
    }

    @Test(arguments: [false, true])
    func `daily entries carry message token counts per day and model`(includeParts: Bool) throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let reference = Date(timeIntervalSince1970: 1_772_798_400)
        let now = Calendar.current.startOfDay(for: reference).addingTimeInterval(12 * 3600)

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL, includeParts: includeParts)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(now.addingTimeInterval(-3600)),
            cost: 3.0,
            model: "claude-sonnet-4-5",
            tokens: [
                "total": 1600,
                "input": 100,
                "output": 20,
                "reasoning": 30,
                "cache": ["read": 1400, "write": 50],
            ])
        // Older OpenCode rows omit `total`; it is the sum of every component.
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(now.addingTimeInterval(-1800)),
            cost: 2.0,
            model: "gpt-5.1-codex",
            tokens: ["input": 10, "output": 5, "reasoning": 1, "cache": ["read": 4, "write": 0]])

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: now, historyDays: 30)

        let entry = try #require(snapshot.daily.first)
        #expect(entry.totalTokens == 1620)
        #expect(entry.inputTokens == 110)
        #expect(entry.outputTokens == 25)
        #expect(entry.reasoningTokens == 31)
        #expect(entry.cacheReadTokens == 1404)
        #expect(entry.cacheCreationTokens == 50)
        let breakdowns = try #require(entry.modelBreakdowns)
        #expect(breakdowns.first { $0.modelName == "claude-sonnet-4-5" }?.totalTokens == 1600)
        #expect(breakdowns.first { $0.modelName == "gpt-5.1-codex" }?.totalTokens == 20)

        let tokenSnapshot = snapshot.toCostUsageTokenSnapshot(historyDays: 30)
        #expect(tokenSnapshot.last30DaysTokens == 1620)
    }

    @Test
    func `step finish tokens replace message tokens when parts exist`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let reference = Date(timeIntervalSince1970: 1_772_798_400)
        let now = Calendar.current.startOfDay(for: reference).addingTimeInterval(12 * 3600)

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        let messageID = try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(now.addingTimeInterval(-3600)),
            cost: 3.0,
            tokens: ["total": 999, "input": 999])
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms(now.addingTimeInterval(-3600)),
            cost: 1.0,
            tokens: ["total": 40, "input": 30, "output": 10])
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL,
            messageID: messageID,
            createdMs: Self.ms(now.addingTimeInterval(-3300)),
            cost: 2.0,
            tokens: ["total": 60, "input": 50, "output": 10])

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: now)

        let entry = try #require(snapshot.daily.first)
        #expect(entry.totalTokens == 100)
        #expect(entry.inputTokens == 80)
        #expect(entry.outputTokens == 20)
    }

    @Test
    func `a day with a tokenless row keeps its token total unknown`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let reference = Date(timeIntervalSince1970: 1_772_798_400)
        let now = Calendar.current.startOfDay(for: reference).addingTimeInterval(12 * 3600)

        try Self.writeAuth(to: env.authURL)
        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(now.addingTimeInterval(-3600)),
            cost: 3.0,
            model: "claude-sonnet-4-5",
            tokens: ["total": 50, "input": 50])
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(now.addingTimeInterval(-1800)),
            cost: 1.0,
            model: "claude-sonnet-4-5")

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
        let snapshot = try reader.fetch(now: now, historyDays: 30)

        let entry = try #require(snapshot.daily.first)
        #expect(entry.costUSD == 4.0)
        #expect(entry.totalTokens == nil)
        #expect(entry.modelBreakdowns?.first?.totalTokens == nil)
        #expect(snapshot.toCostUsageTokenSnapshot(historyDays: 30).last30DaysTokens == nil)
    }

    @Test(arguments: [
        #"{}"#,
        #"[]"#,
        #"12"#,
        #"true"#,
        #""{\"total\": 10}""#,
        #"{"input": 10, "output": 5}"#,
        #"{"total": 10, "input": "10"}"#,
        #"{"total": 10, "input": true}"#,
        #"{"total": 10, "input": 1.5}"#,
        #"{"total": 10, "input": -1}"#,
        #"{"total": -1}"#,
        #"{"total": 9223372036854775808}"#,
        #"{"input": 9223372036854775807, "output": 1, "reasoning": 0, "cache": {"read": 0, "write": 0}}"#,
    ])
    func `invalid or incomplete token records preserve cost without inventing totals`(json: String) throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let tokens = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 2, tokens: tokens)

        let snapshot = try OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
            .fetch(now: now)
        let entry = try #require(snapshot.daily.first)
        #expect(entry.costUSD == 2)
        #expect(entry.requestCount == 1)
        #expect(entry.totalTokens == nil)
        #expect(entry.inputTokens == nil)
        #expect(entry.modelBreakdowns?.first?.totalTokens == nil)
        #expect(snapshot.toCostUsageTokenSnapshot().last30DaysTokens == nil)
    }

    @Test
    func `explicit zero total does not invent missing component counts or dollars`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 0, tokens: ["total": 0])

        let snapshot = try OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
            .fetch(now: now)
        let entry = try #require(snapshot.daily.first)
        #expect(entry.totalTokens == 0)
        #expect(entry.inputTokens == nil)
        #expect(entry.outputTokens == nil)
        #expect(entry.reasoningTokens == nil)
        #expect(entry.cacheReadTokens == nil)
        #expect(entry.cacheCreationTokens == nil)
        #expect(entry.costUSD == 0)
        #expect(snapshot.toCostUsageTokenSnapshot().last30DaysTokens == 0)
    }

    @Test(arguments: [false, true])
    func `overflowing day totals stay unknown across later rows`(differentModels: Bool) throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        for (index, count) in [Int.max, 1, 10].enumerated() {
            try Self.insertMessage(
                databaseURL: env.databaseURL,
                createdMs: Self.ms(now),
                cost: 1,
                model: differentModels ? "test-model-\(index)" : "test-model",
                tokens: ["total": count])
        }

        let snapshot = try OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)
            .fetch(now: now)
        let entry = try #require(snapshot.daily.first)
        #expect(entry.totalTokens == nil)
        #expect(entry.requestCount == 3)
        #expect(entry.costUSD == 3)
        if !differentModels {
            #expect(entry.modelBreakdowns?.first?.totalTokens == nil)
        }
        #expect(snapshot.toCostUsageTokenSnapshot().last30DaysTokens == nil)
    }

    @Test
    func `missing auth and history is not detected`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let reader = OpenCodeGoLocalUsageReader(authURL: env.authURL, databaseURL: env.databaseURL)

        #expect(throws: OpenCodeGoLocalUsageError.notDetected) {
            _ = try reader.fetch(now: Date(timeIntervalSince1970: 1_772_798_400))
        }
    }

    private static func makeEnvironment() throws -> (root: URL, authURL: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeGoLocalUsageReaderTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            root,
            directory.appendingPathComponent("auth.json", isDirectory: false),
            directory.appendingPathComponent("opencode.db", isDirectory: false))
    }

    private static func writeAuth(to url: URL) throws {
        let data = Data(#"{"opencode-go":{"type":"api-key","key":"go-key"}}"#.utf8)
        try data.write(to: url)
    }

    private static func createDatabase(at url: URL, includeParts: Bool = true) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try Self.exec(
            db: db,
            sql: """
                CREATE TABLE message (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  data TEXT NOT NULL,
                  time_created INTEGER,
                  time_updated INTEGER
                );
                CREATE TABLE part (
                  id TEXT PRIMARY KEY,
                  message_id TEXT NOT NULL,
                  session_id TEXT NOT NULL,
                  data TEXT NOT NULL,
                  time_created INTEGER,
                  time_updated INTEGER
                );
            """)
        if !includeParts {
            try Self.exec(db: db, sql: "DROP TABLE part")
        }
    }

    private static func configureIdleWAL(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        do {
            try Self.exec(db: db, sql: "PRAGMA journal_mode = WAL; PRAGMA wal_checkpoint(TRUNCATE);")
        } catch {
            sqlite3_close(db)
            throw error
        }
        guard sqlite3_close(db) == SQLITE_OK else { throw SQLiteTestError.close }

        for suffix in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                try FileManager.default.removeItem(at: sidecarURL)
            }
        }
    }

    @discardableResult
    private static func insertMessage(
        databaseURL: URL,
        createdMs: Int64,
        cost: Double?,
        model: String? = nil,
        tokens: Any? = nil) throws -> String
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        let messageID = UUID().uuidString
        var payload: [String: Any] = [
            "providerID": "opencode-go",
            "role": "assistant",
            "time": ["created": createdMs],
        ]
        if let cost {
            payload["cost"] = cost
        }
        if let model {
            payload["modelID"] = model
        }
        if let tokens {
            payload["tokens"] = tokens
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO message (id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, messageID, -1, transient)
        sqlite3_bind_text(stmt, 2, "session-1", -1, transient)
        sqlite3_bind_text(stmt, 3, json, -1, transient)
        sqlite3_bind_int64(stmt, 4, createdMs)
        sqlite3_bind_int64(stmt, 5, createdMs)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
        return messageID
    }

    private static func insertStepFinishPart(
        databaseURL: URL,
        messageID: String,
        createdMs: Int64,
        cost: Double,
        tokens: [String: Any] = ["input": 1, "output": 1, "total": 2]) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        let payload: [String: Any] = [
            "type": "step-finish",
            "cost": cost,
            "tokens": tokens,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO part (id, message_id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, messageID, -1, transient)
        sqlite3_bind_text(stmt, 3, "session-1", -1, transient)
        sqlite3_bind_text(stmt, 4, json, -1, transient)
        sqlite3_bind_int64(stmt, 5, createdMs)
        sqlite3_bind_int64(stmt, 6, createdMs)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func exec(db: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            sqlite3_free(message)
            throw SQLiteTestError.exec
        }
    }

    private static func ms(_ iso: String) -> Int64 {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Int64((formatter.date(from: iso)?.timeIntervalSince1970 ?? 0) * 1000)
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private enum SQLiteTestError: Error {
        case close
        case open
        case prepare
        case step
        case exec
    }
}

#endif
