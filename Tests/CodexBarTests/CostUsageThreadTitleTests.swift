import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Testing
@testable import CodexBarCore

#if canImport(SQLite3) || canImport(CSQLite3)
struct CostUsageThreadTitleTests {
    @Test
    func `five thousand sessions list each sqlite home once and preserve every field`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = ListingFileManager()

        let result = CostUsageFetcher.codexSessionsWithThreadTitles(
            fixture.sessions,
            sessionsRoot: fixture.home.appendingPathComponent("sessions"),
            environment: ["CODEX_SQLITE_HOME": ".codex"],
            fileManager: manager)

        #expect(result == fixture.expected)
        #expect(manager.listings.count == 3)
        #expect(Set(manager.listings) == Set(fixture.sqliteHomes))
    }

    @Test(arguments: [false, true])
    func `different working directories share the same absolute sqlite home`(configured: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        if configured {
            try "sqlite_home = '\(fixture.home.path)'\n".write(
                to: fixture.home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
        let manager = ListingFileManager()
        let environment = ["CODEX_SQLITE_HOME": configured ? "/unused/environment/home" : fixture.home.path]

        let result = CostUsageFetcher.codexSessionsWithThreadTitles(
            fixture.sessions,
            sessionsRoot: fixture.home.appendingPathComponent("sessions"),
            environment: environment,
            fileManager: manager)

        #expect(result == fixture.sessions.enumerated().map { index, session in
            session.withTitle(index == 0 ? "Explicit name" : "Home 0: \(index)")
        })
        #expect(manager.listings.count == 1)
        #expect(Set(manager.listings) == [fixture.home])
    }

    @Test
    func `next call discovers database versions config and index edits`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = ListingFileManager()
        let sessions = Array(fixture.sessions.prefix(2))
        let sessionsRoot = fixture.home.appendingPathComponent("sessions")
        let initial = CostUsageFetcher.codexSessionsWithThreadTitles(
            sessions, sessionsRoot: sessionsRoot, environment: [:], fileManager: manager)
        #expect(initial.map(\.title) == ["Explicit name", "Home 0: 1"])

        try Fixture.createDatabase(at: fixture.home.appendingPathComponent("state_10.sqlite"), home: 10)
        try "{\"id\":\"session-0\",\"thread_name\":\"Renamed\"}\n".write(
            to: fixture.home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        let newer = CostUsageFetcher.codexSessionsWithThreadTitles(
            sessions, sessionsRoot: sessionsRoot, environment: [:], fileManager: manager)
        #expect(newer.map(\.title) == ["Renamed", "Home 10: 1"])

        try "sqlite_home = '\(fixture.sqliteHomes[1].path)'\n".write(
            to: fixture.home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let redirected = CostUsageFetcher.codexSessionsWithThreadTitles(
            sessions, sessionsRoot: sessionsRoot, environment: [:], fileManager: manager)
        #expect(redirected.map(\.title) == ["Renamed", "Home 1: 1"])
        #expect(manager.listings == [fixture.home, fixture.home, fixture.sqliteHomes[1]])
    }

    @Test
    func `missing sqlite home is attempted only once and retains index and original titles`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = ListingFileManager()
        let missing = fixture.home.appendingPathComponent("missing", isDirectory: true)
        let result = CostUsageFetcher.codexSessionsWithThreadTitles(
            fixture.sessions,
            sessionsRoot: fixture.home.appendingPathComponent("sessions"),
            environment: ["CODEX_SQLITE_HOME": missing.path],
            fileManager: manager)

        #expect(result == fixture.sessions.enumerated().map { index, session in
            index == 0 ? session.withTitle("Explicit name") : session
        })
        #expect(manager.listings.count == 1)
        #expect(Set(manager.listings) == [missing])
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let sqliteHomes: [URL]
        let sessions: [CostUsageSessionBreakdown]
        let expected: [CostUsageSessionBreakdown]

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cost-thread-titles-\(UUID().uuidString)", isDirectory: true)
            self.root = root
            self.home = root.appendingPathComponent("codex", isDirectory: true)
            let projects = (1...2).map { root.appendingPathComponent("project-\($0)", isDirectory: true) }
            self.sqliteHomes = [self.home] + projects.map { $0.appendingPathComponent(".codex", isDirectory: true) }
            for (index, sqliteHome) in self.sqliteHomes.enumerated() {
                try FileManager.default.createDirectory(at: sqliteHome, withIntermediateDirectories: true)
                try Self.createDatabase(at: sqliteHome.appendingPathComponent("state_9.sqlite"), home: index)
                try Data().write(to: sqliteHome.appendingPathComponent("state_5.sqlite"))
            }
            try "model = 'fixture-model'\n".write(
                to: self.home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            try "{\"id\":\"session-0\",\"thread_name\":\"Explicit name\"}\n".write(
                to: self.home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
            self.sessions = (0..<5000).map { index in
                var session = CostUsageSessionBreakdown(
                    sessionID: "session-\(index)",
                    lastActivity: Date(timeIntervalSince1970: Double(index)),
                    inputTokens: index,
                    cachedInputTokens: 1,
                    outputTokens: 2,
                    reasoningTokens: 1,
                    totalTokens: index + 2,
                    requestCount: 1,
                    costUSD: 0.01,
                    modelBreakdowns: [],
                    projectPath: "/synthetic/canonical",
                    projectName: "Synthetic",
                    title: "Original")
                session.workingDirectory = index % 3 == 0 ? nil : projects[index % 3 - 1].path
                return session
            }
            self.expected = self.sessions.enumerated().map { index, session in
                session.withTitle(index == 0 ? "Explicit name" : "Home \(index % 3): \(index)")
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: self.root)
        }

        static func createDatabase(at url: URL, home: Int) throws {
            var database: OpaquePointer?
            #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
            let opened = try #require(database)
            defer { sqlite3_close(opened) }
            let rows = (0..<5000).map { "('session-\($0)', 'Home \(home): \($0)')" }.joined(separator: ",")
            let sql = "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT); INSERT INTO threads VALUES \(rows);"
            #expect(sqlite3_exec(opened, sql, nil, nil, nil) == SQLITE_OK)
        }
    }
}

private final class ListingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    var listings: [URL] {
        self.lock.withLock { self.recorded }
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL]
    {
        self.lock.withLock { self.recorded.append(url) }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
#endif
