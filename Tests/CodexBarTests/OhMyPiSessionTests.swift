import Foundation
import Testing
@testable import CodexBarCore

struct OhMyPiSessionTests {
    @Test
    func `root resolution honors active profile precedence and upstream validation`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiRoots")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let baseEnvironment = [
            "HOME": home.path,
            "PI_CONFIG_DIR": "config",
            "OMP_PROFILE": "work",
            "PI_PROFILE": "other",
        ]
        #expect(Self.paths(OhMyPiSessionRootResolver.sessionRoots(environment: baseEnvironment)) == [
            home.appendingPathComponent("config/profiles/work/agent/sessions").path,
        ])

        var defaultEnvironment = baseEnvironment
        defaultEnvironment["OMP_PROFILE"] = ""
        #expect(Self.paths(OhMyPiSessionRootResolver.sessionRoots(environment: defaultEnvironment)) == [
            home.appendingPathComponent("config/agent/sessions").path,
        ])

        for invalid in ["../work", "work/team", "WORK", "work.", ".", "..", "CON", "con.txt"] {
            var environment = baseEnvironment
            environment["OMP_PROFILE"] = invalid
            #expect(OhMyPiSessionRootResolver.sessionRoots(environment: environment).isEmpty)
        }
    }

    @Test
    func `root resolution rejects config directories outside canonical home`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiConfigEscape")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("linked-config", isDirectory: true),
            withDestinationURL: outside)

        for configDirectory in ["../outside", outside.path, "linked-config"] {
            var defaultEnvironment = [
                "HOME": home.path,
                "PI_CONFIG_DIR": configDirectory,
            ]
            #expect(OhMyPiSessionRootResolver.sessionRoots(environment: defaultEnvironment).isEmpty)

            defaultEnvironment["OMP_PROFILE"] = "work"
            #expect(OhMyPiSessionRootResolver.sessionRoots(environment: defaultEnvironment).isEmpty)
        }
    }

    @Test
    func `root resolution rejects default agent symlinks escaping canonical home`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiAgentEscape")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let config = home.appendingPathComponent(".omp", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: config.appendingPathComponent("agent", isDirectory: true),
            withDestinationURL: outside)

        #expect(OhMyPiSessionRootResolver.sessionRoots(environment: ["HOME": home.path]).isEmpty)
    }

    @Test
    func `root resolution applies XDG migration and custom root precedence`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiXDG")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let xdgData = root.appendingPathComponent("data", isDirectory: true)
        let customAgent = root.appendingPathComponent("custom-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: xdgData.appendingPathComponent("omp/sessions", isDirectory: true),
            withIntermediateDirectories: true)

        let environment = [
            "HOME": home.path,
            "XDG_DATA_HOME": xdgData.path,
        ]
        #expect(Self.paths(OhMyPiSessionRootResolver.sessionRoots(environment: environment)) == [
            xdgData.appendingPathComponent("omp/sessions").path,
        ])

        var customEnvironment = environment
        customEnvironment["PI_CODING_AGENT_DIR"] = customAgent.path
        #expect(Self.paths(OhMyPiSessionRootResolver.sessionRoots(environment: customEnvironment)) == [
            customAgent.appendingPathComponent("sessions").path,
        ])

        #expect(OhMyPiSessionRootResolver.sessionRoots(
            environment: ["PI_CODING_AGENT_DIR": customAgent.path]).isEmpty)

        let profileSessions = xdgData.appendingPathComponent(
            "omp/profiles/work/sessions",
            isDirectory: true)
        try FileManager.default.createDirectory(at: profileSessions, withIntermediateDirectories: true)
        var namedEnvironment = customEnvironment
        namedEnvironment["OMP_PROFILE"] = "work"
        #expect(Self.paths(OhMyPiSessionRootResolver.sessionRoots(environment: namedEnvironment)) == [
            profileSessions.path,
        ])

        try FileManager.default.removeItem(at: profileSessions)
        #expect(Self.paths(OhMyPiSessionRootResolver.sessionRoots(environment: namedEnvironment)) == [
            home.appendingPathComponent(".omp/profiles/work/agent/sessions").path,
        ])
    }

    @Test
    func `file parser handles title slots, bounded metadata, and mtime clamping`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiParser")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let title = String(repeating: "🙂", count: 70) + "\nignored"
        let content = try [
            Self.jsonLine(["type": "title", "title": title]),
            Self.jsonLine([
                "type": "session",
                "id": "session-1",
                "cwd": "/tmp/project/./app",
                "timestamp": "2026-07-30T23:00:00Z",
                "title": "header title",
            ]),
        ].joined()
        try Data(content.utf8).write(to: file)

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let record = try #require(OhMyPiSessionFileParser.parse(
            url: file,
            modifiedAt: now.addingTimeInterval(100),
            now: now))
        #expect(record.id == "session-1")
        #expect(record.cwd == "/tmp/project/./app")
        #expect(record.sessionName?.unicodeScalars.count == 64)
        #expect(record.startedAt == ISO8601DateFormatter().date(from: "2026-07-30T23:00:00Z"))
        #expect(record.modifiedAt == now)
        #expect(record.url == file)
    }

    @Test
    func `file parser rejects malformed truncated and oversized records`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiMalformed")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        let malformed = root.appendingPathComponent("malformed.jsonl")
        try Data("{\"type\":\"session\",\"id\":42}\n".utf8).write(to: malformed)
        #expect(OhMyPiSessionFileParser.parse(url: malformed, modifiedAt: now, now: now) == nil)

        let truncated = root.appendingPathComponent("truncated.jsonl")
        try Data("{\"type\":\"session\",\"id\":\"partial\"".utf8).write(to: truncated)
        #expect(OhMyPiSessionFileParser.parse(url: truncated, modifiedAt: now, now: now) == nil)

        let oversized = root.appendingPathComponent("oversized.jsonl")
        let oversizedLine = "{\"type\":\"session\",\"id\":\"\(String(repeating: "x", count: 20000))\"}\n"
        try Data(oversizedLine.utf8).write(to: oversized)
        #expect(OhMyPiSessionFileParser.parse(url: oversized, modifiedAt: now, now: now) == nil)
    }

    @Test
    func `scanner matches standardized cwd and emits deterministic pid fallbacks`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let agentRoot = root.appendingPathComponent("agent", isDirectory: true)
        let project = agentRoot.appendingPathComponent("sessions/project-a", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("new.jsonl")
        try Data([
            Self.jsonLine(["type": "title", "title": "Fix\nlabels\u{7F}"]),
            Self.jsonLine([
                "type": "session",
                "id": "session-new",
                "cwd": "/tmp/project/./app",
                "timestamp": "2026-07-30T23:00:00Z",
            ]),
        ].joined().utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -5)],
            ofItemAtPath: file.path)

        let now = Date()
        let matchedProcess = AgentProcessRecord(
            pid: 20,
            ppid: 1,
            startedAt: now.addingTimeInterval(-20),
            command: "/usr/local/bin/omp --project /tmp/project/app")
        let unmatchedProcess = AgentProcessRecord(
            pid: 10,
            ppid: 1,
            startedAt: now.addingTimeInterval(-10),
            command: "/usr/local/bin/omp --project /tmp/other")
        var budget = DirectoryMetadataScanBudget(maxEntryCount: 100, maxDepth: 1, timeLimit: 60)
        let sessions = OhMyPiSessionScanner.scan(
            input: OhMyPiSessionScanner.ScanInput(
                processes: [matchedProcess, unmatchedProcess],
                cwdByPID: [20: "/tmp/project/app", 10: "/tmp/other"],
                environment: ["HOME": root.appendingPathComponent("home").path, "PI_CODING_AGENT_DIR": agentRoot.path],
                environmentByPID: [
                    20: ["HOME": root.appendingPathComponent("home").path, "PI_CODING_AGENT_DIR": agentRoot.path],
                    10: ["HOME": root.appendingPathComponent("home").path, "PI_CODING_AGENT_DIR": agentRoot.path],
                ],
                now: now,
                host: "test-host",
                config: SessionScanConfig()),
            directoryBudget: &budget)

        let matched = try #require(sessions.first(where: { $0.id == "session-new" }))
        #expect(matched.provider == .ohMyPi)
        #expect(matched.pid == 20)
        #expect(matched.cwd == "/tmp/project/app")
        #expect(matched.sessionName == "Fixlabels")
        #expect(matched.transcriptPath == file.path)
        #expect(sessions.contains { $0.id == "pid:10" && $0.pid == 10 })
    }

    @Test
    func `scanner omits stale file-only sessions and deduplicates session ids`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiStale")
        defer { try? FileManager.default.removeItem(at: root) }
        let agentRoot = root.appendingPathComponent("agent", isDirectory: true)
        for projectName in ["one", "two"] {
            let project = agentRoot.appendingPathComponent("sessions/\(projectName)", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let file = project.appendingPathComponent("session.jsonl")
            try Data([
                Self.jsonLine(["type": "session", "id": "duplicate", "cwd": "/tmp/project"]),
            ].joined().utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: projectName == "one" ? -20 : -5)],
                ofItemAtPath: file.path)
        }

        let now = Date()
        let process = AgentProcessRecord(
            pid: 30,
            ppid: 1,
            startedAt: now.addingTimeInterval(-60),
            command: "omp")
        var budget = DirectoryMetadataScanBudget(maxEntryCount: 100, maxDepth: 1, timeLimit: 60)
        let environment = ["HOME": root.appendingPathComponent("home").path, "PI_CODING_AGENT_DIR": agentRoot.path]
        let sessions = OhMyPiSessionScanner.scan(
            input: OhMyPiSessionScanner.ScanInput(
                processes: [process],
                cwdByPID: [30: "/tmp/project"],
                environment: environment,
                environmentByPID: [30: environment],
                now: now,
                host: "test-host",
                config: SessionScanConfig()),
            directoryBudget: &budget)
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == "duplicate")

        var emptyBudget = DirectoryMetadataScanBudget(maxEntryCount: 100, maxDepth: 1, timeLimit: 60)
        #expect(OhMyPiSessionScanner.scan(
            input: OhMyPiSessionScanner.ScanInput(
                processes: [],
                cwdByPID: [:],
                environment: environment,
                environmentByPID: [:],
                now: now,
                host: "test-host",
                config: SessionScanConfig()),
            directoryBudget: &emptyBudget).isEmpty)
    }

    @Test
    func `scanner rejects project symlinks escaping the session root and honors budget`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiEscape")
        defer { try? FileManager.default.removeItem(at: root) }
        let agentRoot = root.appendingPathComponent("agent", isDirectory: true)
        let sessionRoot = agentRoot.appendingPathComponent("sessions", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("escape.jsonl")
        try Data([
            Self.jsonLine(["type": "session", "id": "escape", "cwd": "/tmp/escape"]),
        ].joined().utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: sessionRoot.appendingPathComponent("project"),
            withDestinationURL: outside)

        let now = Date()
        let process = AgentProcessRecord(pid: 40, ppid: 1, startedAt: now, command: "omp")
        var budget = DirectoryMetadataScanBudget(maxEntryCount: 100, maxDepth: 1, timeLimit: 60)
        let environment = ["HOME": root.appendingPathComponent("home").path, "PI_CODING_AGENT_DIR": agentRoot.path]
        let escaped = OhMyPiSessionScanner.scan(
            input: OhMyPiSessionScanner.ScanInput(
                processes: [process],
                cwdByPID: [40: "/tmp/escape"],
                environment: environment,
                environmentByPID: [40: environment],
                now: now,
                host: "test-host",
                config: SessionScanConfig()),
            directoryBudget: &budget)
        #expect(escaped.count == 1)
        #expect(escaped.first?.id == "pid:40")
        #expect(escaped.first?.transcriptPath == nil)

        var boundedBudget = DirectoryMetadataScanBudget(maxEntryCount: 1, maxDepth: 1, timeLimit: 60)
        let bounded = OhMyPiSessionScanner.scan(
            input: OhMyPiSessionScanner.ScanInput(
                processes: [process],
                cwdByPID: [40: "/tmp/escape"],
                environment: environment,
                environmentByPID: [40: environment],
                now: now,
                host: "test-host",
                config: SessionScanConfig()),
            directoryBudget: &boundedBudget)
        #expect(bounded.first?.id == "pid:40")
    }

    @Test
    func `oh my pi provider preserves Codable wire value`() throws {
        let session = AgentSession(
            id: "session-1",
            provider: .ohMyPi,
            source: .cli,
            state: .active,
            pid: 41,
            cwd: "/tmp/project",
            projectName: "project",
            sessionName: "A title",
            startedAt: Date(timeIntervalSince1970: 100),
            lastActivityAt: Date(timeIntervalSince1970: 200),
            transcriptPath: "/tmp/session.jsonl",
            host: "test-host")
        let data = try JSONEncoder().encode(session)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["provider"] as? String == "oh-my-pi")
        #expect(try JSONDecoder().decode(AgentSession.self, from: data) == session)
    }

    @Test
    func `local scanner publishes live oh my pi sessions`() async throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiLocalScanner")
        defer { try? FileManager.default.removeItem(at: root) }
        let agentRoot = root.appendingPathComponent("home/agent", isDirectory: true)
        let project = agentRoot.appendingPathComponent("sessions/project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        try Data(Self.jsonLine([
            "type": "session",
            "id": "local-session",
            "cwd": "/tmp/project",
        ]).utf8).write(to: file)

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-5)],
            ofItemAtPath: file.path)
        let environment = [
            "HOME": root.appendingPathComponent("home").path,
        ]
        let processEnvironment = [
            "HOME": root.appendingPathComponent("home").path,
            "PI_CODING_AGENT_DIR": agentRoot.path,
        ]
        let scanner = LocalAgentSessionScanner(
            processOutputProvider: { _ in
                "20 1 Mon Jul 6 09:00:00 2026 /usr/local/bin/omp --project /tmp/project\n"
            },
            cwdProvider: { pids, _ in
                [pids[0]: "/tmp/project"]
            },
            processEnvironmentProvider: { pids, _ in
                pids.reduce(into: [Int32: [String: String]]()) { environments, pid in
                    environments[pid] = processEnvironment
                }
            })

        let sessions = await scanner.scan(
            now: now,
            environment: environment,
            includeFileOnlySessions: false)

        let session = try #require(sessions.first)

        #expect(session.id == "local-session")
        #expect(session.provider == .ohMyPi)
        #expect(session.pid == 20)
        #expect(session.transcriptPath == file.path)
    }

    @Test
    func `scanner resolves each live process against its own active profile`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiPerProcessProfiles")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let firstSessions = home.appendingPathComponent(
            ".omp/profiles/first/agent/sessions/project",
            isDirectory: true)
        let secondSessions = home.appendingPathComponent(
            ".omp/profiles/second/agent/sessions/project",
            isDirectory: true)
        try FileManager.default.createDirectory(at: firstSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_900_000_100)
        let firstFile = firstSessions.appendingPathComponent("first.jsonl")
        let secondFile = secondSessions.appendingPathComponent("second.jsonl")
        try Self.writeSessionFile(
            at: firstFile,
            id: "profile-first",
            cwd: "/tmp/shared-project",
            modifiedAt: now.addingTimeInterval(-5),
            title: "First profile")
        try Self.writeSessionFile(
            at: secondFile,
            id: "profile-second",
            cwd: "/tmp/shared-project",
            modifiedAt: now.addingTimeInterval(-5),
            title: "Second profile")

        let firstEnvironment = ["HOME": home.path, "OMP_PROFILE": "first"]
        let secondEnvironment = ["HOME": home.path, "OMP_PROFILE": "second"]
        let processes = [
            AgentProcessRecord(
                pid: 101,
                ppid: 1,
                startedAt: now.addingTimeInterval(-60),
                command: "/usr/local/bin/omp"),
            AgentProcessRecord(
                pid: 102,
                ppid: 1,
                startedAt: now.addingTimeInterval(-60),
                command: "/usr/local/bin/omp"),
        ]
        var budget = DirectoryMetadataScanBudget(maxEntryCount: 100, maxDepth: 1, timeLimit: 60)
        let sessions = OhMyPiSessionScanner.scan(
            input: OhMyPiSessionScanner.ScanInput(
                processes: processes,
                cwdByPID: [101: "/tmp/shared-project", 102: "/tmp/shared-project"],
                environment: ["HOME": home.path, "OMP_PROFILE": "ambient"],
                environmentByPID: [101: firstEnvironment, 102: secondEnvironment],
                now: now,
                host: "test-host",
                config: SessionScanConfig()),
            directoryBudget: &budget)

        let sessionsByPID = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            session.pid.map { ($0, session) }
        })
        #expect(sessionsByPID[101]?.id == "profile-first")
        #expect(sessionsByPID[101]?.transcriptPath == firstFile.path)
        #expect(sessionsByPID[102]?.id == "profile-second")
        #expect(sessionsByPID[102]?.transcriptPath == secondFile.path)
    }

    @Test
    func `scanner does not leak ambient named profiles when process environment is inaccessible`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiInaccessibleEnvironment")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let ambientSessions = home.appendingPathComponent(
            ".omp/profiles/ambient/agent/sessions/project",
            isDirectory: true)
        try FileManager.default.createDirectory(at: ambientSessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_900_000_200)
        let ambientFile = ambientSessions.appendingPathComponent("ambient.jsonl")
        try Self.writeSessionFile(
            at: ambientFile,
            id: "ambient-only",
            cwd: "/tmp/project",
            modifiedAt: now.addingTimeInterval(-5),
            title: "Must not leak")
        let process = AgentProcessRecord(
            pid: 201,
            ppid: 1,
            startedAt: now.addingTimeInterval(-60),
            command: "/usr/local/bin/omp")
        var budget = DirectoryMetadataScanBudget(maxEntryCount: 100, maxDepth: 1, timeLimit: 60)
        let sessions = OhMyPiSessionScanner.scan(
            input: OhMyPiSessionScanner.ScanInput(
                processes: [process],
                cwdByPID: [201: "/tmp/project"],
                environment: ["HOME": home.path, "OMP_PROFILE": "ambient"],
                environmentByPID: [:],
                now: now,
                host: "test-host",
                config: SessionScanConfig()),
            directoryBudget: &budget)

        let session = try #require(sessions.first)
        #expect(session.id == "pid:201")
        #expect(session.pid == 201)
        #expect(session.sessionName == nil)
        #expect(session.transcriptPath == nil)
        #expect(sessions.allSatisfy { $0.id != "ambient-only" })
    }

    @Test
    func `scanner uses only a valid process HOME for partial environments`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiPartialEnvironment")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let defaultSessions = home.appendingPathComponent(
            ".omp/agent/sessions/project",
            isDirectory: true)
        let ambientSessions = home.appendingPathComponent(
            ".omp/profiles/ambient/agent/sessions/project",
            isDirectory: true)
        try FileManager.default.createDirectory(at: defaultSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ambientSessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_900_000_250)
        let defaultFile = defaultSessions.appendingPathComponent("default.jsonl")
        let ambientFile = ambientSessions.appendingPathComponent("ambient.jsonl")
        try Self.writeSessionFile(
            at: defaultFile,
            id: "default-only",
            cwd: "/tmp/project",
            modifiedAt: now.addingTimeInterval(-5))
        try Self.writeSessionFile(
            at: ambientFile,
            id: "ambient-only",
            cwd: "/tmp/project",
            modifiedAt: now.addingTimeInterval(-5))

        let processes = [
            AgentProcessRecord(
                pid: 211,
                ppid: 1,
                startedAt: now.addingTimeInterval(-60),
                command: "/usr/local/bin/omp"),
            AgentProcessRecord(
                pid: 212,
                ppid: 1,
                startedAt: now.addingTimeInterval(-60),
                command: "/usr/local/bin/omp"),
            AgentProcessRecord(
                pid: 213,
                ppid: 1,
                startedAt: now.addingTimeInterval(-60),
                command: "/usr/local/bin/omp"),
        ]
        var budget = DirectoryMetadataScanBudget(maxEntryCount: 100, maxDepth: 1, timeLimit: 60)
        let sessions = OhMyPiSessionScanner.scan(
            input: OhMyPiSessionScanner.ScanInput(
                processes: processes,
                cwdByPID: [211: "/tmp/project", 212: "/tmp/project", 213: "/tmp/project"],
                environment: ["HOME": home.path, "OMP_PROFILE": "ambient"],
                environmentByPID: [
                    211: [:],
                    212: ["HOME": home.path],
                ],
                now: now,
                host: "test-host",
                config: SessionScanConfig()),
            directoryBudget: &budget)

        let sessionsByPID = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            session.pid.map { ($0, session) }
        })
        #expect(sessionsByPID[211]?.id == "pid:211")
        #expect(sessionsByPID[211]?.transcriptPath == nil)
        #expect(sessionsByPID[212]?.id == "default-only")
        #expect(sessionsByPID[212]?.transcriptPath == defaultFile.path)
        #expect(sessionsByPID[213]?.id == "pid:213")
        #expect(sessionsByPID[213]?.transcriptPath == nil)
        #expect(sessions.allSatisfy { $0.id != "ambient-only" })
    }

    @Test
    func `scanner rejects records older than process start and accepts equal modification time`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiFreshness")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let agentRoot = home.appendingPathComponent("agent", isDirectory: true)
        let staleProject = agentRoot.appendingPathComponent("sessions/stale", isDirectory: true)
        let equalProject = agentRoot.appendingPathComponent("sessions/equal", isDirectory: true)
        try FileManager.default.createDirectory(at: staleProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: equalProject, withIntermediateDirectories: true)

        let equalMTime = Date(timeIntervalSince1970: 1_900_000_300)
        let now = equalMTime.addingTimeInterval(100)
        let staleFile = staleProject.appendingPathComponent("stale.jsonl")
        let equalFile = equalProject.appendingPathComponent("equal.jsonl")
        try Self.writeSessionFile(
            at: staleFile,
            id: "stale-record",
            cwd: "/tmp/stale",
            modifiedAt: equalMTime.addingTimeInterval(-1))
        try Self.writeSessionFile(
            at: equalFile,
            id: "equal-record",
            cwd: "/tmp/equal",
            modifiedAt: equalMTime)

        let environment = ["HOME": home.path, "PI_CODING_AGENT_DIR": agentRoot.path]
        let processes = [
            AgentProcessRecord(
                pid: 301,
                ppid: 1,
                startedAt: equalMTime,
                command: "/usr/local/bin/omp"),
            AgentProcessRecord(
                pid: 302,
                ppid: 1,
                startedAt: equalMTime,
                command: "/usr/local/bin/omp"),
        ]
        var budget = DirectoryMetadataScanBudget(maxEntryCount: 100, maxDepth: 1, timeLimit: 60)
        let sessions = OhMyPiSessionScanner.scan(
            input: OhMyPiSessionScanner.ScanInput(
                processes: processes,
                cwdByPID: [301: "/tmp/stale", 302: "/tmp/equal"],
                environment: environment,
                environmentByPID: [301: environment, 302: environment],
                now: now,
                host: "test-host",
                config: SessionScanConfig()),
            directoryBudget: &budget)

        let sessionsByPID = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            session.pid.map { ($0, session) }
        })
        #expect(sessionsByPID[301]?.id == "pid:301")
        #expect(sessionsByPID[301]?.transcriptPath == nil)
        #expect(sessionsByPID[302]?.id == "equal-record")
        #expect(sessionsByPID[302]?.transcriptPath == equalFile.path)
    }

    @Test
    func `scanner allocates each record once in deterministic order`() throws {
        let root = try Self.temporaryDirectory(named: "OhMyPiDeterministicAllocation")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let agentRoot = home.appendingPathComponent("agent", isDirectory: true)
        let project = agentRoot.appendingPathComponent("sessions/project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let recordMTime = Date(timeIntervalSince1970: 1_900_000_400)
        let now = recordMTime.addingTimeInterval(100)
        let alphaFile = project.appendingPathComponent("z-session.jsonl")
        let betaFile = project.appendingPathComponent("a-session.jsonl")
        try Self.writeSessionFile(
            at: alphaFile,
            id: "z-session",
            cwd: "/tmp/shared",
            modifiedAt: recordMTime)
        try Self.writeSessionFile(
            at: betaFile,
            id: "a-session",
            cwd: "/tmp/shared",
            modifiedAt: recordMTime)

        let environment = ["HOME": home.path, "PI_CODING_AGENT_DIR": agentRoot.path]
        let processes = [
            AgentProcessRecord(
                pid: 401,
                ppid: 1,
                startedAt: recordMTime,
                command: "/usr/local/bin/omp"),
            AgentProcessRecord(
                pid: 402,
                ppid: 1,
                startedAt: recordMTime,
                command: "/usr/local/bin/omp"),
        ]
        var budget = DirectoryMetadataScanBudget(maxEntryCount: 100, maxDepth: 1, timeLimit: 60)
        let sessions = OhMyPiSessionScanner.scan(
            input: OhMyPiSessionScanner.ScanInput(
                processes: processes,
                cwdByPID: [401: "/tmp/shared", 402: "/tmp/shared"],
                environment: environment,
                environmentByPID: [401: environment, 402: environment],
                now: now,
                host: "test-host",
                config: SessionScanConfig()),
            directoryBudget: &budget)

        let sessionsByPID = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            session.pid.map { ($0, session) }
        })
        #expect(sessionsByPID[402]?.id == "a-session")
        #expect(sessionsByPID[401]?.id == "z-session")
        #expect(sessions.count == 2)
        #expect(Set(sessions.compactMap(\.transcriptPath)).count == 2)
        #expect(Set(sessions.map(\.id)) == ["a-session", "z-session"])
    }

    private static func temporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return try #require(String(bytes: data, encoding: .utf8)) + "\n"
    }

    private static func writeSessionFile(
        at url: URL,
        id: String,
        cwd: String,
        modifiedAt: Date,
        title: String? = nil) throws
    {
        var lines: [String] = []
        if let title {
            try lines.append(Self.jsonLine(["type": "title", "title": title]))
        }
        try lines.append(Self.jsonLine([
            "type": "session",
            "id": id,
            "cwd": cwd,
        ]))
        try Data(lines.joined().utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path)
    }

    private static func paths(_ urls: [URL]) -> [String] {
        urls.map(\.path)
    }
}
