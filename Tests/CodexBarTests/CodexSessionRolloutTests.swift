import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Testing
@testable import CodexBarCore

struct CodexSessionRolloutTests {
    @Test
    func `first rollout line maps to file only agent session`() throws {
        let url = try AgentSessionParserTests.fixtureURL("agent-session-rollout", extension: "jsonl")
        let metadata = try #require(CodexRolloutFirstLineParser.read(from: url))
        let now = Date(timeIntervalSince1970: 10000)
        let modifiedAt = now.addingTimeInterval(-60)
        let session = try #require(CodexRolloutFirstLineParser.makeSession(
            metadata: metadata,
            transcriptURL: url,
            modifiedAt: modifiedAt,
            host: "local-mac",
            now: now))

        #expect(session.id == "019f-session-fixture")
        #expect(session.cwd == "/Users/test/Projects/alpha")
        #expect(session.projectName == "alpha")
        #expect(session.source == .cli)
        #expect(session.state == .active)
        #expect(session.pid == nil)
    }

    @Test
    func `file only rollout outside window is excluded while live process remains`() throws {
        let url = try AgentSessionParserTests.fixtureURL("agent-session-rollout", extension: "jsonl")
        let metadata = try #require(CodexRolloutFirstLineParser.read(from: url))
        let now = Date(timeIntervalSince1970: 10000)
        let modifiedAt = now.addingTimeInterval(-1801)

        #expect(CodexRolloutFirstLineParser.makeSession(
            metadata: metadata,
            transcriptURL: url,
            modifiedAt: modifiedAt,
            host: "local-mac",
            now: now) == nil)
        #expect(CodexRolloutFirstLineParser.makeSession(
            metadata: metadata,
            transcriptURL: url,
            modifiedAt: modifiedAt,
            pid: 42,
            host: "local-mac",
            now: now)?.state == .idle)
    }

    @Test
    func `app server presence classifies unknown file only rollout as desktop`() {
        #expect(AgentSessionCorrelation.fileOnlyCodexSource(
            metadataSource: .unknown,
            appServerPresent: true) == .desktopApp)
        #expect(AgentSessionCorrelation.fileOnlyCodexSource(
            metadataSource: .unknown,
            appServerPresent: false) == .unknown)
    }

    @Test
    func `codex cwd matching rejects missing paths`() {
        #expect(AgentSessionCorrelation.codexWorkingDirectoriesMatch("/repo/alpha", "/repo/./alpha"))
        #expect(!AgentSessionCorrelation.codexWorkingDirectoriesMatch(nil, nil))
        #expect(!AgentSessionCorrelation.codexWorkingDirectoriesMatch("/repo/alpha", nil))
    }

    @Test
    func `local scanner parses only its newest configured rollout candidates`() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CodexSessionRolloutTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        let codexHome = temporaryRoot.appendingPathComponent("codex-home", isDirectory: true)
        let sessionDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(formatter.string(from: now), isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let fixtureURL = try AgentSessionParserTests.fixtureURL("agent-session-rollout", extension: "jsonl")
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        for (index, age) in [30.0, 20.0, -3600.0].enumerated() {
            let id = "bounded-rollout-\(index)"
            let url = sessionDirectory.appendingPathComponent("rollout-bounded-\(index).jsonl")
            try fixture
                .replacingOccurrences(of: "019f-session-fixture", with: id)
                .write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.modificationDate: now.addingTimeInterval(-age)],
                ofItemAtPath: url.path)
        }

        let scanner = LocalAgentSessionScanner(config: SessionScanConfig(
            fileOnlyWindow: 60 * 60,
            maxProcessCount: 0,
            maxCodexRolloutCount: 2,
            maxClaudeTranscriptCountPerProject: 0))
        let sessions = await scanner.scan(now: now, environment: [
            "CODEX_HOME": codexHome.path,
            "HOME": temporaryRoot.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ])

        #expect(Set(sessions.map(\.id)) == ["bounded-rollout-1", "bounded-rollout-2"])
        #expect(sessions.first(where: { $0.id == "bounded-rollout-2" })?.lastActivityAt == now)

        let rescanned = await scanner.scan(
            now: now.addingTimeInterval(30),
            environment: [
                "CODEX_HOME": codexHome.path,
                "HOME": temporaryRoot.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ])
        #expect(rescanned.first(where: { $0.id == "bounded-rollout-2" })?.lastActivityAt == now)
    }

    @Test
    func `subagent and guardian rollout metadata produce descriptive names`() throws {
        let subagentLine =
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"subagent\",\"cwd\":\"/repo\"," +
            "\"originator\":\"codex_vscode\",\"source\":{\"subagent\":{\"thread_spawn\":{\"agent_path\":" +
            "\"/root/neon_patch_review2\"}}}}}"
        let guardianLine =
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"guardian\",\"cwd\":\"/repo\"," +
            "\"originator\":\"codex_vscode\",\"source\":{\"subagent\":{\"other\":\"guardian\"}}}}"

        let subagent = try #require(CodexRolloutFirstLineParser.parse(subagentLine))
        let guardian = try #require(CodexRolloutFirstLineParser.parse(guardianLine))

        #expect(subagent.agentPath == "/root/neon_patch_review2")
        #expect(subagent.descriptiveName(threadMetadata: nil) == "Neon patch review 2")
        #expect(guardian.isGuardian)
        #expect(guardian.descriptiveName(threadMetadata: nil) == "Approval review")
    }

    @Test
    func `current rollout agent path produces a descriptive subagent name without sqlite`() throws {
        let line =
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"subagent\",\"cwd\":\"/repo\"," +
            "\"originator\":\"codex_vscode\",\"source\":\"subagent\"," +
            "\"agent_path\":\"/root/config_audit3\"}}"

        let metadata = try #require(CodexRolloutFirstLineParser.parse(line))

        #expect(metadata.agentPath == "/root/config_audit3")
        #expect(metadata.descriptiveName(threadMetadata: nil) == "Config audit 3")
    }

    @Test
    func `thread titles skip command preambles and stay menu sized`() {
        let metadata = CodexRolloutMetadata(
            sessionID: "main",
            cwd: "/repo",
            originator: "codex_vscode",
            source: "vscode")
        let title = """
        /brain-orient

        Continue work on the Concrete Authority website and compare every current source before changing anything.
        """

        let name = metadata.descriptiveName(threadMetadata: CodexThreadMetadata(
            title: title,
            agentPath: nil))
        #expect(name == "Continue work on the Concrete Authority website and compare eve…")
        #expect(name?.count == 64)
    }

    @Test
    func `live scanner suppresses descriptive names for ambiguous same project processes`() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CodexSessionRolloutTests-ambiguous-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sessionDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(formatter.string(from: now), isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        for (index, name) in ["recent_activity", "older_activity"].enumerated() {
            let line =
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"session-\(index)\",\"cwd\":\"/repo\"," +
                "\"originator\":\"codex_cli\",\"source\":{\"subagent\":{\"thread_spawn\":{\"agent_path\":" +
                "\"/root/\(name)\"}}}}}"
            let url = sessionDirectory.appendingPathComponent("rollout-ambiguous-\(index).jsonl")
            try line.write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.modificationDate: now.addingTimeInterval(TimeInterval(-index * 30))],
                ofItemAtPath: url.path)
        }

        let scanner = LocalAgentSessionScanner(
            processOutputProvider: { _ in
                """
                201 1 Mon Jul 6 09:03:00 2026 /usr/local/bin/codex exec
                202 1 Tue Jul 7 09:03:00 2026 /usr/local/bin/codex exec
                """
            },
            cwdProvider: { _, _ in [201: "/repo", 202: "/repo"] })
        let sessions = await scanner.scan(
            now: now,
            environment: [
                "CODEX_HOME": codexHome.path,
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            includeFileOnlySessions: false)

        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { $0.projectName == "repo" })
        #expect(sessions.allSatisfy { $0.sessionName == nil })
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    @Test
    func `scanner resolves relative sqlite homes for multiple session projects`() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CodexSessionRolloutTests-relative-sqlite-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sessionDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(formatter.string(from: now), isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        for index in 0..<2 {
            let project = root.appendingPathComponent("project-\(index)", isDirectory: true)
            let sqliteHome = project.appendingPathComponent("relative-state", isDirectory: true)
            try fileManager.createDirectory(at: sqliteHome, withIntermediateDirectories: true)
            let sessionID = "relative-session-\(index)"
            let line =
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sessionID)\",\"cwd\":\"\(project.path)\"," +
                "\"originator\":\"codex_cli\",\"source\":\"cli\"}}"
            try line.write(
                to: sessionDirectory.appendingPathComponent("rollout-relative-\(index).jsonl"),
                atomically: true,
                encoding: .utf8)
            try Self.createThreadDatabase(
                at: sqliteHome.appendingPathComponent("state_5.sqlite"),
                sessionID: sessionID,
                title: "Project \(index) title")
        }

        let scanner = LocalAgentSessionScanner(config: SessionScanConfig(
            maxProcessCount: 0,
            maxClaudeTranscriptCountPerProject: 0))
        let sessions = await scanner.scan(now: now, environment: [
            "CODEX_HOME": codexHome.path,
            "CODEX_SQLITE_HOME": "relative-state",
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ])

        #expect(Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.sessionName) }) == [
            "relative-session-0": "Project 0 title",
            "relative-session-1": "Project 1 title",
        ])
    }

    private static func createThreadDatabase(
        at url: URL,
        sessionID: String,
        title: String) throws
    {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw SQLiteFixtureError.open
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, agent_path TEXT);",
            nil,
            nil,
            nil) == SQLITE_OK
        else { throw SQLiteFixtureError.exec }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO threads (id, title, agent_path) VALUES (?1, ?2, NULL);",
            -1,
            &statement,
            nil) == SQLITE_OK,
            let statement
        else { throw SQLiteFixtureError.exec }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, sessionID, -1, transient)
        sqlite3_bind_text(statement, 2, title, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteFixtureError.exec }
    }

    private enum SQLiteFixtureError: Error {
        case open
        case exec
    }
    #endif
}
