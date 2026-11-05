import Foundation
import Testing
@testable import CodexBarCore

struct GrokLocalSessionScannerTests {
    @Test(arguments: [1, 7, 30])
    func `scan totals cover only the advertised local calendar days`(days: Int) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-window-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_787_079_600))
        let now = today.addingTimeInterval(12 * 3600)
        let outside = try #require(calendar.date(byAdding: .day, value: -days, to: today))
        let first = try #require(calendar.date(byAdding: .day, value: -(days - 1), to: today))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        let dates = [
            outside.addingTimeInterval(18 * 3600),
            first.addingTimeInterval(3600),
            today.addingTimeInterval(2 * 3600),
            tomorrow.addingTimeInterval(3600),
        ]
        for (index, date) in dates.enumerated() {
            let session = home.appendingPathComponent("sessions/project/session-\(index)")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            try self.writeSignals(
                at: session.appendingPathComponent("signals.json"), tokens: 100, model: "example-model", date: date)
        }

        let summary = GrokLocalSessionScanner.summarize(env: ["GROK_HOME": home.path], lookbackDays: days, now: now)
        #expect(summary.sessionCount == 2)
        #expect(summary.totalTokens == 200)
        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: days))
        #expect(snapshot.summary(forLastDays: days, calendar: calendar).totalTokens == snapshot.last30DaysTokens)
    }

    @Test
    func `daily buckets stay local and never invent dollars`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-session-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
    func `usage file turns count tokens the signals file has compacted away`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-usage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let session = home.appendingPathComponent("sessions/project/session-a")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        try self.writeSignals(
            at: session.appendingPathComponent("signals.json"),
            tokens: 100,
            model: "grok-4.7",
            date: now)
        try self.writeUsage(in: session, turns: [(now, 4000, "grok-4.7"), (now, 1000, "grok-4.6")], modified: now)

        let summary = GrokLocalSessionScanner.summarize(env: ["GROK_HOME": home.path], lookbackDays: 7, now: now)

        #expect(summary.sessionCount == 1)
        #expect(summary.totalTokens == 5000)
        #expect(summary.daily.map(\.sessionCount) == [1])
        #expect(Set(summary.models) == ["grok-4.7", "grok-4.6"])
    }

    @Test
    func `usage file turns land on the day they ended and respect the window`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-days-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let session = home.appendingPathComponent("sessions/project/session-a")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_787_079_600)).addingTimeInterval(12 * 3600)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
        let outside = try #require(calendar.date(byAdding: .day, value: -7, to: now))
        try self.writeUsage(
            in: session,
            turns: [(outside, 9000, "grok-4.6"), (yesterday, 300, "grok-4.7"), (now, 200, "grok-4.7")],
            modified: now)

        let summary = GrokLocalSessionScanner.summarize(env: ["GROK_HOME": home.path], lookbackDays: 7, now: now)

        #expect(summary.totalTokens == 500)
        #expect(summary.daily.map(\.totalTokens) == [300, 200])
        #expect(summary.daily.map(\.sessionCount) == [1, 1])
        #expect(summary.sessionCount == 1)
        #expect(summary.lastSessionAt.map { abs($0.timeIntervalSince(now)) < 1 } == true)
        #expect(!summary.models.contains("grok-4.6"))
    }

    @Test
    func `usage file costs stay hidden until dollars are a separate decision`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-cost-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let session = home.appendingPathComponent("sessions/project/session-a")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        try self.writeUsage(in: session, turns: [(now, 200, "grok-4.7")], modified: now)

        let summary = GrokLocalSessionScanner.summarize(env: ["GROK_HOME": home.path], lookbackDays: 7, now: now)
        let snapshot = try #require(summary.toCostUsageTokenSnapshot(historyDays: 7))

        #expect(snapshot.last30DaysTokens == 200)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.daily.allSatisfy { $0.costUSD == nil })
    }

    @Test(arguments: ["not json", #"{"session":{}}"#, #"{"turns":[]}"#, #"{"turns":[{"totalTokens":5}]}"#])
    func `unusable usage file falls back to the signals file`(contents: String) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-fallback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let session = home.appendingPathComponent("sessions/project/session-a")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        try self.writeSignals(
            at: session.appendingPathComponent("signals.json"),
            tokens: 100,
            model: "grok-4.7",
            date: now)
        try contents.write(to: session.appendingPathComponent("usage.json"), atomically: true, encoding: .utf8)

        let summary = GrokLocalSessionScanner.summarize(env: ["GROK_HOME": home.path], lookbackDays: 7, now: now)

        #expect(summary.sessionCount == 1)
        #expect(summary.totalTokens == 100)
    }

    /// Mirrors a real grok CLI `usage.json`, including its microsecond `endedAt` format.
    private func writeUsage(in session: URL, turns: [(Date, Int, String)], modified: Date) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'176+00:00'"
        let records: [[String: Any]] = turns.enumerated().map { index, turn in
            [
                "turnNumber": index + 1,
                "endedAt": formatter.string(from: turn.0),
                "totalTokens": turn.1,
                "costUsdTicks": 10_000_000_000,
                "primaryModelId": turn.2,
                "modelUsage": [turn.2: ["totalTokens": turn.1, "costUsdTicks": 10_000_000_000]],
            ]
        }
        let url = session.appendingPathComponent("usage.json")
        let data = try JSONSerialization.data(withJSONObject: ["sessionId": "session-a", "turns": records])
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test
    func `idle days do not reuse yesterday as today`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-session-idle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
    func `only session root signals contribute to local usage`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let session = home.appendingPathComponent("sessions/project/session")
        let nested = session.appendingPathComponent("artifacts/nested-session")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        try self.writeSignals(
            at: session.appendingPathComponent("signals.json"),
            tokens: 100,
            model: "example-model",
            date: now)
        try self.writeSignals(
            at: nested.appendingPathComponent("signals.json"),
            tokens: 900,
            model: "artifact-model",
            date: now)
        try Data("unrelated".utf8).write(to: home.appendingPathComponent("sessions/project/unrelated.txt"))

        let fileManager = GrokScanRecordingFileManager()
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": home.path], fileManager: fileManager, now: now)
        #expect(summary.sessionCount == 1)
        #expect(summary.totalTokens == 100)
        #expect(summary.lastSessionAt == now)
        #expect(summary.primaryModel == "example-model")
        #expect(summary.models == ["example-model"])
        #expect(summary.scannedAt == now)
        let day = try #require(GrokLocalSessionScanner.dayKey(for: now, calendar: .current))
        #expect(summary.daily == [GrokLocalDailyBucket(
            date: day, totalTokens: 100, sessionCount: 1, models: ["example-model"])])
        #expect(Set(fileManager.visitedNames) == ["project", "session", "unrelated.txt"])
    }

    @Test(arguments: ["missing", "empty", "unavailable"])
    func `empty homes do not publish a spend snapshot`(state: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-session-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if state != "missing" {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        }
        let fileManager = GrokScanRecordingFileManager()
        fileManager.refusesEnumeration = state == "unavailable"
        let now = Date(timeIntervalSince1970: 1_787_079_600)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            fileManager: fileManager,
            lookbackDays: 7,
            now: now)
        #expect(summary.sessionCount == 0)
        #expect(summary.totalTokens == 0)
        #expect(summary.lastSessionAt == nil)
        #expect(summary.primaryModel == nil)
        #expect(summary.models.isEmpty)
        #expect(summary.daily.isEmpty)
        #expect(summary.scannedAt == now)
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

private final class GrokScanRecordingFileManager: FileManager, @unchecked Sendable {
    var visitedNames: [String] = []
    var refusesEnumeration = false

    /// The public Swift overlay delegates to this overridable Foundation entry point.
    override func __enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = [],
        errorHandler handler: ((URL, Error) -> Bool)? = nil) -> FileManager.DirectoryEnumerator?
    {
        guard !self.refusesEnumeration, let enumerator = super.__enumerator(
            at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler)
        else { return nil }
        return GrokScanRecordingEnumerator(base: enumerator) { self.visitedNames.append($0.lastPathComponent) }
    }
}

private final class GrokScanRecordingEnumerator: FileManager.DirectoryEnumerator {
    let base: FileManager.DirectoryEnumerator
    let record: (URL) -> Void

    init(base: FileManager.DirectoryEnumerator, record: @escaping (URL) -> Void) {
        self.base = base
        self.record = record
    }

    override var level: Int {
        self.base.level
    }

    override func nextObject() -> Any? {
        let object = self.base.nextObject()
        if let url = object as? URL { self.record(url) }
        return object
    }

    override func skipDescendants() {
        self.base.skipDescendants()
    }
}
