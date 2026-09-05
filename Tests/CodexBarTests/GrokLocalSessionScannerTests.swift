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
        #expect(summary.totalTokens == 350)
        #expect(summary.daily.map(\.totalTokens) == [100, 250])
        #expect(Set(summary.daily.map(\.date)).count == 2)

        let snapshot = summary.toCostUsageTokenSnapshot(historyDays: 7)
        #expect(snapshot.last30DaysTokens == 350)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.daily.allSatisfy { $0.costUSD == nil })
        #expect(snapshot.costProvenance == .unknown)
        #expect(snapshot.sessionTokens == 250)
    }

    @Test
    func `incomplete legacy history does not fabricate an idle-day zero`() throws {
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
        let snapshot = summary.toCostUsageTokenSnapshot(historyDays: 7)
        #expect(snapshot.last30DaysTokens == 100)
        #expect(snapshot.sessionTokens == nil)
        #expect(snapshot.sessionRequests == nil)
    }

    @Test
    func `incomplete empty homes publish an unestablished spend snapshot`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-session-empty-\(UUID().uuidString)", isDirectory: true)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            lookbackDays: 7,
            now: Date())
        let snapshot = summary.toCostUsageTokenSnapshot(historyDays: 7)
        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(snapshot.daily.isEmpty)
        #expect(snapshot.sessionTokens == nil)
    }

    @Test
    func `readable empty sessions publish established empty history`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-session-readable-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            lookbackDays: 7,
            now: Date())
        #expect(summary.historyCoverageIsEstablished)
        let snapshot = summary.toCostUsageTokenSnapshot(historyDays: 7)
        #expect(snapshot.sessionTokens == 0)
        #expect(snapshot.last30DaysTokens == 0)
        #expect(snapshot.sessionRequests == nil)
        #expect(snapshot.last30DaysRequests == nil)
        #expect(snapshot.daily.isEmpty)
        #expect(snapshot.historyCoverageIsEstablished)
    }

    @Test
    func `enumeration failure keeps an empty scan incomplete`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-enumeration-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            lookbackDays: 7,
            now: Date(),
            byteBudget: GrokLocalSessionScanner.defaultTotalReadBytes,
            sessionEnumerator: Self.failingEnumeration())
        #expect(summary.totalTokens == 0)
        #expect(summary.daily.isEmpty)
        #expect(!summary.historyCoverageIsEstablished)
        let snapshot = summary.toCostUsageTokenSnapshot(historyDays: 7)
        #expect(snapshot.sessionTokens == nil)
        #expect(snapshot.last30DaysTokens == nil)
    }

    @Test
    func `enumeration failure preserves counted totals as incomplete`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-enumeration-partial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("sessions/%2Ftmp%2Fdemo/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        try """
        {"params":{"update":{"usage":{"inputTokens":100,"outputTokens":50,"totalTokens":150}}},\
        "_meta":{"eventId":"ev-1","agentTimestampMs":\(timestampMs)}}
        """.write(to: session.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            lookbackDays: 30,
            now: Date(),
            byteBudget: GrokLocalSessionScanner.defaultTotalReadBytes,
            sessionEnumerator: Self.failingEnumeration())
        #expect(summary.totalTokens == 150)
        #expect(!summary.historyCoverageIsEstablished)
    }

    @Test
    func `discovery cap exhaustion stays incomplete`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-discovery-cap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)
        let summary = GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": root.path],
            lookbackDays: 7,
            now: Date(),
            byteBudget: GrokLocalSessionScanner.defaultTotalReadBytes,
            sessionEnumerator: GrokSessionDirectoryEnumerator { _ in
                GrokDiscoveredSessions(
                    directories: [],
                    enumerationFailed: false,
                    discoveryCapped: true)
            })
        #expect(summary.totalTokens == 0)
        #expect(!summary.historyCoverageIsEstablished)
    }

    @Test
    func `local scan clock wins over a stale remote snapshot`() throws {
        let calendar = Calendar.current
        let staleRemoteTime = Date(timeIntervalSince1970: 1_787_079_600)
        let localScanTime = try #require(calendar.date(byAdding: .day, value: 1, to: staleRemoteTime))
        let localDay = try #require(GrokLocalSessionScanner.dayKey(for: localScanTime, calendar: calendar))
        let summary = GrokLocalSessionSummary(
            totalTokens: 250,
            daily: [GrokLocalDailyBucket(
                date: localDay,
                totalTokens: 250,
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

    private static func failingEnumeration() -> GrokSessionDirectoryEnumerator {
        GrokSessionDirectoryEnumerator { root in
            let listing = try GrokSessionDirectoryEnumerator.live(
                fileManager: FileManager.default,
                maximumEntries: GrokLocalSessionScanner.maximumDiscoveredEntries,
                checkCancellation: {}).enumerate(root)
            return GrokDiscoveredSessions(
                directories: listing.directories,
                enumerationFailed: true,
                discoveryCapped: listing.discoveryCapped)
        }
    }
}
