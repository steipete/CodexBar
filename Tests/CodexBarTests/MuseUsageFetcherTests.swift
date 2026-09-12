import Foundation
import Testing
@testable import CodexBarCore

struct MuseUsageFetcherTests {
    @Test
    func `settings reader reads API key from environment`() {
        let env = ["META_API_KEY": "meta-key-123"]
        let settings = MuseSettingsReader.readSettings(environment: env)
        #expect(settings.apiKey == "meta-key-123")
        #expect(!settings.isContributor)
    }

    @Test
    func `settings reader reads fallback API key from MUSE_API_KEY`() {
        let env = ["MUSE_API_KEY": "muse-key-456"]
        let settings = MuseSettingsReader.readSettings(environment: env)
        #expect(settings.apiKey == "muse-key-456")
        #expect(!settings.isContributor)
    }

    @Test
    func `settings reader parses JSON config file`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configFile = root.appendingPathComponent("settings.json")
        let json = """
        {
            "api_key": "config-key-789",
            "tier": "contributor",
            "model": "muse-spark-1.3"
        }
        """
        try json.write(to: configFile, atomically: true, encoding: .utf8)

        let settings = MuseSettingsReader.readSettings(environment: [:], configURL: configFile)
        #expect(settings.apiKey == "config-key-789")
        #expect(settings.isContributor)
        #expect(settings.defaultModel == "muse-spark-1.3")
    }

    @Test
    func `status probe detects config and sessions`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-probe-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("config", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configFile = configDir.appendingPathComponent("settings.json")
        try "{\"tier\":\"Everyday\"}".write(to: configFile, atomically: true, encoding: .utf8)
        try "{}".write(to: sessionsDir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)

        let probe = MuseStatusProbe.probe(
            environment: [
                "MUSE_CONFIG_FILE": configFile.path,
                "MUSE_SESSIONS_DIR": sessionsDir.path,
            ])

        #expect(probe.hasConfig)
        #expect(probe.hasSessions)
    }

    @Test
    func `usage fetcher reports local token totals without inventing quota windows`() async throws {
        let root = try Self.makeRoot("fetcher")
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Self.fixedNow
        let calendar = Self.utcCalendar
        // Today: 40K. Six days ago: 20K (inside the 7-day window). Seven days ago: outside, even though the
        // parser's one-day scan padding returns it. Eight days ago: outside. Undated: rejected.
        let sessionJSON = """
        {
            "id": "session-today",
            "messages": [
                {"timestamp": "\(Self.iso(now))", "model": "muse-spark-1.3",
                 "usage": {"input_tokens": 30000, "output_tokens": 10000}},
                {"timestamp": "\(Self.iso(now, daysAgo: 6))", "model": "muse-spark-1.3",
                 "usage": {"input_tokens": 15000, "output_tokens": 5000}},
                {"timestamp": "\(Self.iso(now, daysAgo: 7))", "model": "muse-spark-1.3",
                 "usage": {"input_tokens": 700000, "output_tokens": 7000}},
                {"timestamp": "\(Self.iso(now, daysAgo: 8))", "model": "muse-spark-1.3",
                 "usage": {"input_tokens": 999000, "output_tokens": 1000}},
                {"model": "muse-spark-1.3", "usage": {"input_tokens": 500000, "output_tokens": 500000}}
            ]
        }
        """
        try sessionJSON.write(
            to: sessionsDir.appendingPathComponent("session.json"),
            atomically: true,
            encoding: .utf8)

        let snapshot = try await MuseUsageFetcher.fetchUsage(
            environment: ["META_API_KEY": "test-key"],
            sessionRoots: [sessionsDir],
            configURL: root.appendingPathComponent("missing-settings.json"),
            now: now,
            calendar: calendar)

        #expect(snapshot.identity?.providerID == .muse)
        #expect(snapshot.identity?.loginMethod == "today 40K · 7d 60K")
        #expect(snapshot.identity?.accountOrganization == nil)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.tertiary == nil)
        #expect(snapshot.subscriptionRenewsAt == nil)
        #expect(snapshot.subscriptionExpiresAt == nil)
    }

    @Test
    func `usage fetcher surfaces the plan tier from Muse settings`() async throws {
        let root = try Self.makeRoot("fetcher-plan")
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        try "{\"plan\":\"Contributor\",\"email\":\"dev@example.com\"}".write(
            to: settings, atomically: true, encoding: .utf8)
        try "{\"timestamp\":\"\(Self.iso(Self.fixedNow))\",\"input_tokens\":10,\"output_tokens\":1}".write(
            to: sessionsDir.appendingPathComponent("s.json"), atomically: true, encoding: .utf8)

        let snapshot = try await MuseUsageFetcher.fetchUsage(
            environment: [:],
            sessionRoots: [sessionsDir],
            configURL: settings,
            now: Self.fixedNow,
            calendar: Self.utcCalendar)
        #expect(snapshot.identity?.accountOrganization == "Contributor")
        #expect(snapshot.identity?.accountEmail == "dev@example.com")
    }

    @Test
    func `usage fetcher reports missing session directories instead of empty usage`() async throws {
        let root = try Self.makeRoot("fetcher-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("nope", isDirectory: true)

        await #expect(throws: MuseUsageError.sessionLogsUnavailable(searched: [missing.path])) {
            try await MuseUsageFetcher.fetchUsage(
                environment: [:],
                sessionRoots: [missing],
                configURL: root.appendingPathComponent("missing-settings.json"),
                now: Self.fixedNow,
                calendar: Self.utcCalendar)
        }
    }

    @Test
    func `usage fetcher reports an empty session directory instead of empty usage`() async throws {
        let root = try Self.makeRoot("fetcher-empty")
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: MuseUsageError.noSessionLogs(searched: [sessionsDir.path])) {
            try await MuseUsageFetcher.fetchUsage(
                environment: [:],
                sessionRoots: [sessionsDir],
                configURL: root.appendingPathComponent("missing-settings.json"),
                now: Self.fixedNow,
                calendar: Self.utcCalendar)
        }
    }

    @Test
    func `usage fetcher treats a session log with no model calls as measured zero usage`() async throws {
        let root = try Self.makeRoot("fetcher-zero")
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "{\"schema_version\":1,\"record_type\":\"event\",\"payload_type\":\"session.start\"}\n".write(
            to: sessionsDir.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8)

        let snapshot = try await MuseUsageFetcher.fetchUsage(
            environment: [:],
            sessionRoots: [sessionsDir],
            configURL: root.appendingPathComponent("missing-settings.json"),
            now: Self.fixedNow,
            calendar: Self.utcCalendar)
        #expect(snapshot.identity?.loginMethod == "today 0 · 7d 0")
        #expect(snapshot.primary == nil)
    }

    @Test
    func `usage fetcher treats unreadable session logs as unavailable telemetry`() async throws {
        let root = try Self.makeRoot("fetcher-corrupt")
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "{ corrupted".write(to: sessionsDir.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
        try "not json\nstill not\n".write(
            to: sessionsDir.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)

        await #expect(throws: MuseUsageError.noSessionLogs(searched: [sessionsDir.path])) {
            try await MuseUsageFetcher.fetchUsage(
                environment: [:],
                sessionRoots: [sessionsDir],
                configURL: root.appendingPathComponent("missing-settings.json"),
                now: Self.fixedNow,
                calendar: Self.utcCalendar)
        }
    }

    private static let fixedNow: Date = ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z")!

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func iso(_ date: Date, daysAgo: Int = 0) -> String {
        let shifted = Self.utcCalendar.date(byAdding: .day, value: -daysAgo, to: date) ?? date
        return ISO8601DateFormatter().string(from: shifted)
    }

    private static func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
