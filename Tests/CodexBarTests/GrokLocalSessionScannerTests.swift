import Foundation
import Testing
@testable import CodexBarCore

struct GrokLocalSessionScannerTests {
    @Test
    func `daily buckets stay local and never invent dollars`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-session-scan-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("sessions/%2Ftmp%2Fdemo", isDirectory: true)
        let first = cwd.appendingPathComponent("session-a", isDirectory: true)
        let second = cwd.appendingPathComponent("session-b", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let calendar = Calendar.current
        let newer = Date(timeIntervalSince1970: 1_787_079_600)
        let older = try #require(calendar.date(byAdding: .day, value: -1, to: newer))
        try self.writeSignals(
            at: first.appendingPathComponent("signals.json"),
            tokens: 100,
            model: "grok-4.6",
            date: older)
        try self.writeSignals(
            at: second.appendingPathComponent("signals.json"),
            tokens: 250,
            model: "grok-4.6",
            date: newer)

        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            lookbackDays: 7,
            now: newer)
        #expect(summary.sessionCount == 2)
        #expect(summary.totalTokens == 350)
        #expect(summary.daily.map(\.totalTokens) == [100, 250])
        #expect(summary.daily.map(\.sessionCount) == [1, 1])
        #expect(Set(summary.daily.map(\.date)).count == 2)

        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: 7))
        #expect(snapshot.last30DaysTokens == 350)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.daily.allSatisfy { $0.costUSD == nil })
        #expect(snapshot.costProvenance == .unknown)
        #expect(snapshot.sessionTokens == 250)
    }

    @Test
    func `idle days do not reuse yesterday as today`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-session-idle-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fdemo/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let calendar = Calendar.current
        let yesterday = Date(timeIntervalSince1970: 1_787_079_600)
        let today = try #require(calendar.date(byAdding: .day, value: 1, to: yesterday))
        try self.writeSignals(
            at: session.appendingPathComponent("signals.json"),
            tokens: 100,
            model: "grok-4.6",
            date: yesterday)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            lookbackDays: 7,
            now: today)
        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: 7))
        #expect(snapshot.last30DaysTokens == 100)
        #expect(snapshot.sessionTokens == nil)
    }

    @Test
    func `empty homes do not publish a spend snapshot`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-session-empty-\(UUID().uuidString)", isDirectory: true)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            lookbackDays: 7,
            now: Date())
        #expect(summary.toCostUsageTokenSnapshot(historyDays: 7) == nil)
    }

    @Test
    func `local scan clock wins over a stale remote snapshot`() throws {
        let calendar = Calendar.current
        let staleRemoteTime = Date(timeIntervalSince1970: 1_787_079_600)
        let localScanTime = try #require(calendar.date(byAdding: .day, value: 1, to: staleRemoteTime))
        let localDay = try #require(GrokLocalSessionScanner.dayKey(for: localScanTime, calendar: calendar))
        let summary = GrokLocalSessionSummary(
            sessionCount: 1,
            totalTokens: 250,
            lastSessionAt: localScanTime,
            primaryModel: "grok-4.6",
            models: ["grok-4.6"],
            daily: [GrokLocalDailyBucket(
                date: localDay,
                totalTokens: 250,
                sessionCount: 1,
                models: ["grok-4.6"])],
            scannedAt: localScanTime)
        let remote = GrokUsageSnapshot(
            billing: nil,
            credentials: nil,
            localSummary: summary,
            cliVersion: nil,
            updatedAt: staleRemoteTime)

        let snapshot = try #require(remote.toUsageSnapshot().costUsage)
        #expect(snapshot.sessionTokens == 250)
        #expect(snapshot.updatedAt == localScanTime)
    }

    @Test
    func `turn usage replaces signal context and stays token-only`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-turn-token-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fdemo/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let when = Date(timeIntervalSince1970: 1_787_079_600)
        try self.writeSignals(
            at: session.appendingPathComponent("signals.json"),
            tokens: 10,
            model: "grok-4.6",
            date: when)
        let usage = """
        {"timestamp":1787079600,"method":"_x.ai/session/update",\
        "params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":1000,\
        "outputTokens":50,"totalTokens":1050,"cachedReadTokens":200,"cacheCreationTokens":0,\
        "reasoningTokens":10,"modelUsage":{"grok-4.6-build":{"inputTokens":1000,"outputTokens":50,\
        "totalTokens":1050,"cachedReadTokens":200,"cacheCreationTokens":0,"reasoningTokens":10}}}}}}
        """
        try usage.write(to: session.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: when],
            ofItemAtPath: session.appendingPathComponent("updates.jsonl").path)

        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            fileManager: .default,
            lookbackDays: 7,
            now: when)
        #expect(summary.totalTokens == 1050)
        #expect(summary.daily.map(\.requestCount) == [1])
        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: 7))
        #expect(snapshot.last30DaysTokens == 1050)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.costProvenance == .unknown)
        #expect(snapshot.historyCoverageIsEstablished)
    }

    @Test
    func `turns outside the requested window are excluded`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-turn-window-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fdemo/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let when = Date(timeIntervalSince1970: 1_787_079_600)
        let old = 1_787_079_600 - (40 * 24 * 60 * 60)
        let usage = """
        {"timestamp":\(old),"method":"_x.ai/session/update",\
        "params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"old","usage":{"inputTokens":400,\
        "outputTokens":100,"totalTokens":500,"cachedReadTokens":0,"cacheCreationTokens":0,\
        "modelUsage":{"grok-4.6":{"inputTokens":400,"outputTokens":100,"totalTokens":500,\
        "cachedReadTokens":0,"cacheCreationTokens":0}}}}}}
        {"timestamp":1787079600,"method":"_x.ai/session/update",\
        "params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"new","usage":{"inputTokens":1000,\
        "outputTokens":50,"totalTokens":1050,"cachedReadTokens":200,"cacheCreationTokens":0,\
        "modelUsage":{"grok-4.6-build":{"inputTokens":1000,"outputTokens":50,"totalTokens":1050,\
        "cachedReadTokens":200,"cacheCreationTokens":0}}}}}}
        """
        let updates = session.appendingPathComponent("updates.jsonl")
        try usage.write(to: updates, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: updates.path)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            fileManager: .default,
            lookbackDays: 7,
            now: when)
        #expect(summary.totalTokens == 1050)
    }

    @Test
    func `one day reports count today only`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-turn-calendar-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fdemo/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_787_079_600))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        let now = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: today))
        let yesterdayEvening = try #require(calendar.date(bySettingHour: 15, minute: 0, second: 0, of: yesterday))
        let thisMorning = try #require(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: today))
        let tomorrowMorning = try #require(calendar.date(bySettingHour: 1, minute: 0, second: 0, of: tomorrow))
        let usage = [
            self.turnLine(prompt: "yesterday", model: "grok-4.6", at: yesterdayEvening, input: 400, output: 100),
            self.turnLine(prompt: "today", model: "grok-4.6-build", at: thisMorning, input: 1000, output: 50),
            self.turnLine(prompt: "tomorrow", model: "grok-4.6", at: tomorrowMorning, input: 2000, output: 100),
        ].joined(separator: "\n")
        let updates = session.appendingPathComponent("updates.jsonl")
        try usage.write(to: updates, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: updates.path)

        let todayOnly = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            fileManager: .default,
            lookbackDays: 1,
            now: now)
        let todayKey = try #require(GrokLocalSessionScanner.dayKey(for: now, calendar: calendar))
        #expect(todayOnly.totalTokens == 1050)
        #expect(todayOnly.daily.map(\.date) == [todayKey])
        let todaySnapshot = try #require(todayOnly.toCostUsageTokenSnapshot(historyDays: 1))
        #expect(todaySnapshot.sessionTokens == 1050)
        #expect(todaySnapshot.last30DaysTokens == 1050)
        #expect(todaySnapshot.last30DaysCostUSD == nil)

        let twoDays = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            fileManager: .default,
            lookbackDays: 2,
            now: now)
        #expect(twoDays.totalTokens == 1550)
        #expect(twoDays.daily.count == 2)
    }

    @Test
    func `repeated prompt keeps the latest turn`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-turn-replay-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fdemo/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let when = Date(timeIntervalSince1970: 1_787_079_600)
        try self.writeSignals(
            at: session.appendingPathComponent("signals.json"),
            tokens: 10,
            model: "grok-4.6",
            date: when)
        let usage = [
            self.turnLine(prompt: "p1", model: "grok-4.6", at: when, input: 1000, output: 50),
            self.turnLine(prompt: "p1", model: "grok-4.6", at: when, input: 2000, output: 100),
        ].joined(separator: "\n")
        let updates = session.appendingPathComponent("updates.jsonl")
        try usage.write(to: updates, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: updates.path)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            fileManager: .default,
            lookbackDays: 7,
            now: when)
        #expect(summary.totalTokens == 2100)
        #expect(summary.daily.map(\.requestCount) == [1])
    }

    @Test
    func `multi model turn counts each model`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-turn-fanout-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fdemo/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let when = Date(timeIntervalSince1970: 1_787_079_600)
        let usage = """
        {"timestamp":1787079600,"method":"_x.ai/session/update",\
        "params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{\
        "modelUsage":{"grok-4.6":{"inputTokens":400,"outputTokens":100,"totalTokens":500},\
        "grok-4.6-build":{"inputTokens":1000,"outputTokens":50,"totalTokens":1050}}}}}}
        """
        let updates = session.appendingPathComponent("updates.jsonl")
        try usage.write(to: updates, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: updates.path)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            fileManager: .default,
            lookbackDays: 7,
            now: when)
        #expect(summary.totalTokens == 1550)
        #expect(summary.daily.map(\.requestCount) == [2])
        #expect(summary.daily.first?.models == ["grok-4.6", "grok-4.6-build"])
    }

    @Test
    func `future signals outside the window are excluded`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-signal-future-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fdemo/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let when = Date(timeIntervalSince1970: 1_787_079_600)
        let future = Date(timeIntervalSince1970: 1_787_079_600 + (2 * 24 * 60 * 60))
        try self.writeSignals(
            at: session.appendingPathComponent("signals.json"),
            tokens: 9999,
            model: "grok-4.6",
            date: future)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            fileManager: .default,
            lookbackDays: 7,
            now: when)
        #expect(summary.totalTokens == 0)
        #expect(summary.daily.isEmpty)
        #expect(summary.toCostUsageTokenSnapshot(historyDays: 7) == nil)
    }

    @Test
    func `oversized turn log marks coverage partial`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-turn-oversized-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fdemo/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let when = Date(timeIntervalSince1970: 1_787_079_600)
        try self.writeSignals(
            at: session.appendingPathComponent("signals.json"),
            tokens: 500,
            model: "grok-4.6",
            date: when)
        let updates = session.appendingPathComponent("updates.jsonl")
        try Data(count: (32 * 1024 * 1024) + 1).write(to: updates)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: updates.path)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            fileManager: .default,
            lookbackDays: 7,
            now: when)
        #expect(summary.totalTokens == 500)
        #expect(summary.historyCoverageIsEstablished == false)
        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: 7))
        #expect(snapshot.historyCoverageIsEstablished == false)
    }

    private func turnLine(prompt: String, model: String, at: Date, input: Int, output: Int) -> String {
        let timestamp = Int(at.timeIntervalSince1970)
        return """
        {"timestamp":\(timestamp),"method":"_x.ai/session/update",\
        "params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"\(prompt)","usage":{"inputTokens":\(input),\
        "outputTokens":\(output),"totalTokens":\(input + output),"cachedReadTokens":0,"cacheCreationTokens":0,\
        "modelUsage":{"\(model)":{"inputTokens":\(input),"outputTokens":\(output),\
        "totalTokens":\(input + output),"cachedReadTokens":0,"cacheCreationTokens":0}}}}}}
        """
    }

    private func writeSignals(at url: URL, tokens: Int, model: String, date: Date) throws {
        let payload: [String: Any] = [
            "contextTokensUsed": tokens,
            "totalTokensBeforeCompaction": 0,
            "primaryModelId": model,
            "modelsUsed": [model],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
