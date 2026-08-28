import Foundation
import Testing
@testable import CodexBarCore

struct PiFamilySessionTests {
    @Test
    func `fixture parsers cover plain pi omp title and legacy header dialects`() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let piURL = try Self.fixtureFile(
            "PiFamily/pi/--tmp-pi-family-project--/2026-08-03T12-00-00-000Z_pi-fixture.jsonl")
        let hashedOMPBucket = "abs-pi-family-project-" +
            "0bff77ccc1794123b5c69216e8a176e470093f8ebe392db0e42a2df5b9f5d17a"
        let ompURL = try Self.fixtureFile("PiFamily/omp/\(hashedOMPBucket)/" +
            "2026-08-03T12-00-00-000Z_omp-fixture.jsonl")
        let legacyURL = try Self.fixtureFile(
            "PiFamily/omp-legacy/--tmp-pi-family-project--/2026-08-03T11-00-00-000Z_omp-legacy.jsonl")

        let pi = try #require(PiFamilySessionFileParser.parse(
            url: piURL,
            dialect: .pi,
            modifiedAt: now,
            now: now))
        #expect(pi.id == "pi-fixture")
        #expect(pi.cwd == "/tmp/pi-family-project")
        #expect(pi.sessionName == "Plain pi fixture")

        let omp = try #require(PiFamilySessionFileParser.parse(
            url: ompURL,
            dialect: .omp,
            modifiedAt: now,
            now: now))
        #expect(omp.id == "omp-fixture")
        #expect(omp.sessionName == "OMP fixture")
        #expect(ompURL.deletingLastPathComponent().lastPathComponent.hasPrefix("abs-pi-family-project-"))

        let legacy = try #require(PiFamilySessionFileParser.parse(
            url: legacyURL,
            dialect: .omp,
            modifiedAt: now,
            now: now))
        #expect(legacy.id == "omp-legacy")
        #expect(legacy.sessionName == "OMP legacy fixture")
        #expect(legacyURL.deletingLastPathComponent().lastPathComponent == "--tmp-pi-family-project--")
    }

    @Test
    func `plain pi session info reads from the tail and bounds labels to 64 scalars`() throws {
        let root = try Self.temporaryDirectory(named: "PiTailTitle")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let title = String(repeating: "🙂", count: 70) + "\nignored"
        var content = try Self.jsonLine([
            "type": "session",
            "version": 3,
            "id": "tail-title",
            "timestamp": "2026-08-03T12:00:00.000Z",
            "cwd": "/tmp/project",
        ])
        content += String(repeating: "{\"type\":\"custom\",\"data\":\"padding-padding-padding\"}\n", count: 2000)
        content += try Self.jsonLine(["type": "session_info", "name": title])
        try Data(content.utf8).write(to: file)

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let record = try #require(PiFamilySessionFileParser.parse(
            url: file,
            dialect: .pi,
            modifiedAt: now.addingTimeInterval(30),
            now: now))
        #expect(record.sessionName?.unicodeScalars.count == 64)
        #expect(record.sessionName == String(repeating: "🙂", count: 64))
        #expect(record.modifiedAt == now)
    }

    @Test
    func `process classification recognizes both pi dialects and excludes helpers`() {
        let records = [
            Self.process(pid: 1, command: "pi"),
            Self.process(pid: 2, command: "/usr/local/bin/pi --model test"),
            Self.process(pid: 3, command: "omp --profile work"),
            Self.process(pid: 4, command: "bun /tools/oh-my-pi/omp"),
            Self.process(pid: 5, command: "pi --help"),
            Self.process(pid: 6, command: "omp --version"),
            Self.process(pid: 7, command: "bun /tools/unrelated.js"),
        ]

        let agents = AgentPSOutputParser.agentProcesses(from: records)
        #expect(agents.map(\.pid) == [1, 2, 3, 4])
        #expect(AgentPSOutputParser.piDialect(for: records[0]) == .pi)
        #expect(AgentPSOutputParser.piDialect(for: records[2]) == .omp)
        #expect(AgentPSOutputParser.piDialect(for: records[3]) == .omp)
        #expect(AgentPSOutputParser.provider(for: records[0]) == .pi)
        #expect(AgentPSOutputParser.provider(for: records[2]) == .pi)
    }

    @Test
    func `scanner correlates fixture directories for both dialects`() throws {
        let root = try Self.temporaryDirectory(named: "PiFamilyFixtures")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let piRoot = home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        let ompRoot = home.appendingPathComponent(".omp/agent/sessions", isDirectory: true)
        try Self.copyFixtureDirectory("PiFamily/pi", to: piRoot)
        try Self.copyFixtureDirectory("PiFamily/omp", to: ompRoot)

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        try Self.setJSONModificationDates(in: home, to: now.addingTimeInterval(-5))
        let sessions = Self.scan(
            processes: [
                Self.process(pid: 11, startedAt: now.addingTimeInterval(-60), command: "pi"),
                Self.process(pid: 12, startedAt: now.addingTimeInterval(-60), command: "omp"),
            ],
            cwdByPID: [11: "/tmp/pi-family-project", 12: "/tmp/pi-family-project"],
            environment: ["HOME": home.path],
            now: now)

        #expect(sessions.count == 2)
        let byDialect = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            session.dialect.map { ($0, session) }
        })
        #expect(byDialect[.pi]?.id == "pi-fixture")
        #expect(byDialect[.pi]?.sessionName == "Plain pi fixture")
        #expect(byDialect[.omp]?.id == "omp-fixture")
        #expect(byDialect[.omp]?.sessionName == "OMP fixture")
        #expect(sessions.allSatisfy { $0.provider == .pi && $0.transcriptPath != nil })
    }

    @Test
    func `scanner uses legacy omp buckets and xdg roots`() throws {
        let root = try Self.temporaryDirectory(named: "PiFamilyXDG")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let xdg = root.appendingPathComponent("xdg", isDirectory: true)
        let sessionsRoot = xdg.appendingPathComponent("omp/sessions", isDirectory: true)
        try Self.copyFixtureDirectory("PiFamily/omp-legacy", to: sessionsRoot)

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        try Self.setJSONModificationDates(in: xdg, to: now.addingTimeInterval(-5))
        let sessions = Self.scan(
            processes: [Self.process(pid: 20, startedAt: now.addingTimeInterval(-60), command: "omp")],
            cwdByPID: [20: "/tmp/pi-family-project"],
            environment: ["HOME": home.path, "XDG_DATA_HOME": xdg.path],
            now: now)

        let session = try #require(sessions.first)
        #expect(session.id == "omp-legacy")
        #expect(session.dialect == .omp)
        #expect(session.sessionName == "OMP legacy fixture")
    }

    @Test
    func `custom session directories resolve from cli and plain pi settings`() throws {
        let root = try Self.temporaryDirectory(named: "PiCustomRoots")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let cwd = root.appendingPathComponent("project", isDirectory: true)
        let cliSessions = root.appendingPathComponent("cli-sessions", isDirectory: true)
        let settingsSessions = root.appendingPathComponent("settings-sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cwd.appendingPathComponent(".pi"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cliSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settingsSessions, withIntermediateDirectories: true)
        try Data("{\"sessionDir\":\"\(settingsSessions.path)\"}\n".utf8)
            .write(to: cwd.appendingPathComponent(".pi/settings.json"))

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        try Self.writeSession(
            at: cliSessions.appendingPathComponent("omp.jsonl"),
            dialect: .omp,
            id: "omp-custom",
            cwd: cwd.path,
            modifiedAt: now.addingTimeInterval(-5))
        try Self.writeSession(
            at: settingsSessions.appendingPathComponent("pi.jsonl"),
            dialect: .pi,
            id: "pi-settings",
            cwd: cwd.path,
            modifiedAt: now.addingTimeInterval(-5))

        let sessions = Self.scan(
            processes: [
                Self.process(
                    pid: 31,
                    startedAt: now.addingTimeInterval(-60),
                    command: "omp --session-dir \(cliSessions.path)"),
                Self.process(pid: 32, startedAt: now.addingTimeInterval(-60), command: "pi"),
            ],
            cwdByPID: [31: cwd.path, 32: cwd.path],
            environment: ["HOME": home.path],
            now: now)

        #expect(Set(sessions.map(\.id)) == ["omp-custom", "pi-settings"])
        #expect(sessions.first { $0.id == "omp-custom" }?.dialect == .omp)
        #expect(sessions.first { $0.id == "pi-settings" }?.dialect == .pi)
    }

    @Test
    func `missing jsonl and unresolved custom roots retain pid only rows`() throws {
        let root = try Self.temporaryDirectory(named: "PiPIDOnly")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let sessions = Self.scan(
            processes: [
                Self.process(pid: 41, startedAt: now.addingTimeInterval(-10), command: "pi"),
                Self.process(pid: 42, startedAt: now.addingTimeInterval(-10), command: "omp --profile missing"),
            ],
            cwdByPID: [41: "/tmp/no-jsonl-pi", 42: "/tmp/no-jsonl-omp"],
            environment: ["HOME": root.path],
            now: now)

        #expect(Set(sessions.map(\.id)) == ["pid:41", "pid:42"])
        #expect(sessions.allSatisfy { $0.transcriptPath == nil && $0.state == .active })
        #expect(Set(sessions.compactMap(\.dialect)) == [.pi, .omp])
    }

    @Test
    func `correlation assigns each transcript once and leaves unmatched processes visible`() throws {
        let root = try Self.temporaryDirectory(named: "PiCorrelation")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = home.appendingPathComponent(".pi/agent/sessions/--tmp-correlation--", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        try Self.writeSession(
            at: project.appendingPathComponent("one.jsonl"),
            dialect: .pi,
            id: "one-session",
            cwd: "/tmp/correlation",
            modifiedAt: now.addingTimeInterval(-5))

        let sessions = Self.scan(
            processes: [
                Self.process(pid: 51, startedAt: now.addingTimeInterval(-30), command: "pi"),
                Self.process(pid: 52, startedAt: now.addingTimeInterval(-20), command: "pi"),
            ],
            cwdByPID: [51: "/tmp/correlation", 52: "/tmp/correlation"],
            environment: ["HOME": home.path],
            now: now)

        #expect(sessions.count == 2)
        #expect(sessions.count(where: { $0.id == "one-session" }) == 1)
        #expect(sessions.count(where: { $0.id.hasPrefix("pid:") }) == 1)
        #expect(Set(sessions.compactMap(\.transcriptPath)).count == 1)
    }

    private static func scan(
        processes: [AgentProcessRecord],
        cwdByPID: [Int32: String],
        environment: [String: String],
        now: Date) -> [AgentSession]
    {
        var budget = DirectoryMetadataScanBudget(maxEntryCount: 512, maxDepth: 1, timeLimit: 5)
        return PiFamilySessionScanner.scan(
            input: PiFamilySessionScanner.ScanInput(
                processes: processes,
                cwdByPID: cwdByPID,
                environment: environment,
                now: now,
                host: "fixture-host",
                config: SessionScanConfig()),
            directoryBudget: &budget)
    }

    private static func process(
        pid: Int32,
        startedAt: Date? = Date(timeIntervalSince1970: 1_899_999_900),
        command: String) -> AgentProcessRecord
    {
        AgentProcessRecord(pid: pid, ppid: 1, startedAt: startedAt, command: command)
    }

    private static func fixtureFile(_ relativePath: String) throws -> URL {
        let fixtures = try #require(Bundle.module.resourceURL?.appendingPathComponent("Fixtures", isDirectory: true))
        let url = fixtures.appendingPathComponent(relativePath)
        #expect(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    private static func copyFixtureDirectory(_ relativePath: String, to destination: URL) throws {
        let fixtures = try #require(Bundle.module.resourceURL?.appendingPathComponent("Fixtures", isDirectory: true))
        let source = fixtures.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func setJSONModificationDates(in root: URL, to date: Date) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    private static func writeSession(
        at url: URL,
        dialect: AgentSession.Dialect,
        id: String,
        cwd: String,
        modifiedAt: Date) throws
    {
        var lines: [String] = []
        if dialect == .omp {
            try lines.append(Self.jsonLine(["type": "title", "v": 1, "title": "Custom OMP"]))
        }
        try lines.append(Self.jsonLine([
            "type": "session",
            "version": 3,
            "id": id,
            "timestamp": "2026-08-03T12:00:00.000Z",
            "cwd": cwd,
        ]))
        if dialect == .pi {
            try lines.append(Self.jsonLine(["type": "session_info", "name": "Custom pi"]))
        }
        try Data(lines.joined().utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    private static func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(data: data, encoding: .utf8)) + "\n"
    }

    private static func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
