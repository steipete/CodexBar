import CodexBarCore
import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Testing

#if canImport(SQLite3) || canImport(CSQLite3)
struct CodexThreadMetadataReaderTests {
    @Test
    func `reader loads titles and agent paths without writing to codex state`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-thread-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("state_5.sqlite")
        try Self.createDatabase(at: databaseURL)

        let metadata = CodexThreadMetadataReader(databaseURL: databaseURL).metadata(for: ["main", "subagent"])

        #expect(metadata["main"] == CodexThreadMetadata(title: "Fix Claude reauthorization", agentPath: nil))
        #expect(metadata["subagent"] == CodexThreadMetadata(
            title: "Inherited parent title",
            agentPath: "/root/neon_patch_review2"))
    }

    @Test
    func `reader honors configured sqlite home before the environment`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-thread-metadata-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let configuredHome = root.appendingPathComponent("configured-sqlite", isDirectory: true)
        let environmentHome = root.appendingPathComponent("environment-sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuredHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: environmentHome, withIntermediateDirectories: true)
        let config = """
        developer_instructions = ""\"
        [not_a_real_table]
        sqlite_home = '/not/the/real/path'
        ""\"
        sqlite_home = '\(configuredHome.path)'

        """
        try config
            .write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let databaseURL = configuredHome.appendingPathComponent("state_9.sqlite")
        try Self.createDatabase(at: databaseURL)

        let reader = CodexThreadMetadataReader(
            codexHomeDirectory: codexHome,
            environment: ["CODEX_SQLITE_HOME": environmentHome.path])

        #expect(reader.databaseURL.resolvingSymlinksInPath() == databaseURL.resolvingSymlinksInPath())
        #expect(reader.metadata(for: ["main"])["main"]?.title == "Fix Claude reauthorization")
    }

    @Test
    func `reader accepts quoted sqlite key and multiline path`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-thread-metadata-multiline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let sqliteHome = root.appendingPathComponent("configured-sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sqliteHome, withIntermediateDirectories: true)
        let escapedPath = sqliteHome.path.replacingOccurrences(of: "configured", with: "config\\u0075red")
        try "\"sqlite_home\" = \"\"\"\\\n  \(escapedPath)\"\"\"\n"
            .write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let databaseURL = sqliteHome.appendingPathComponent("state_8.sqlite")
        try Self.createDatabase(at: databaseURL)

        let reader = CodexThreadMetadataReader(codexHomeDirectory: codexHome)

        #expect(reader.databaseURL.resolvingSymlinksInPath() == databaseURL.resolvingSymlinksInPath())
    }

    @Test
    func `reader preserves parent traversal after a symlink`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-thread-metadata-symlink-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target/project", isDirectory: true)
        let state = root.appendingPathComponent("target/state", isDirectory: true)
        let link = root.appendingPathComponent("project-link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = state.appendingPathComponent("state_6.sqlite")
        try Self.createDatabase(at: databaseURL)

        let reader = CodexThreadMetadataReader(
            codexHomeDirectory: root.appendingPathComponent("codex", isDirectory: true),
            environment: ["CODEX_SQLITE_HOME": link.path + "/../state"])

        #expect(reader.databaseURL.resolvingSymlinksInPath() == databaseURL.resolvingSymlinksInPath())
    }

    @Test
    func `reader resolves relative sqlite environment against the session cwd`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-thread-metadata-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        let sqliteHome = workingDirectory.appendingPathComponent("relative-sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sqliteHome, withIntermediateDirectories: true)
        let databaseURL = sqliteHome.appendingPathComponent("state_7.sqlite")
        try Self.createDatabase(at: databaseURL)

        let reader = CodexThreadMetadataReader(
            codexHomeDirectory: codexHome,
            environment: ["CODEX_SQLITE_HOME": "relative-sqlite"],
            resolvedWorkingDirectory: workingDirectory)

        #expect(reader.databaseURL.resolvingSymlinksInPath() == databaseURL.resolvingSymlinksInPath())
    }

    @Test
    func `reader prefers the latest explicit thread name over the sqlite title`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-thread-metadata-name-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.createDatabase(at: root.appendingPathComponent("state_5.sqlite"))
        let index = """
        {"id":"main","thread_name":"Initial name","updated_at":"2026-01-01T00:00:00Z"}
        not-json
        {"id":"main","thread_name":"Chosen name","updated_at":"2026-01-02T00:00:00Z"}
        {"id":"other","thread_name":"Other name","updated_at":"2026-01-03T00:00:00Z"}

        """
        try index.write(
            to: root.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8)

        let metadata = CodexThreadMetadataReader(codexHomeDirectory: root).metadata(for: ["main", "subagent"])

        #expect(metadata["main"]?.title == "Chosen name")
        #expect(metadata["subagent"]?.title == "Inherited parent title")
        #expect(metadata["subagent"]?.agentPath == "/root/neon_patch_review2")
    }

    @Test
    func `reader returns an explicit thread name without sqlite state`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-thread-metadata-index-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "{\"id\":\"main\",\"thread_name\":\"Chosen name\",\"updated_at\":\"now\"}\n"
            .write(
                to: root.appendingPathComponent("session_index.jsonl"),
                atomically: true,
                encoding: .utf8)

        let metadata = CodexThreadMetadataReader(codexHomeDirectory: root).metadata(for: ["main"])

        #expect(metadata["main"] == CodexThreadMetadata(title: "Chosen name", agentPath: nil))
    }

    private static func createDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw SQLiteError.open
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, agent_path TEXT);
        INSERT INTO threads VALUES ('main', 'Fix Claude reauthorization', NULL);
        INSERT INTO threads VALUES ('subagent', 'Inherited parent title', '/root/neon_patch_review2');
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.exec
        }
    }

    private enum SQLiteError: Error {
        case open
        case exec
    }
}
#endif
