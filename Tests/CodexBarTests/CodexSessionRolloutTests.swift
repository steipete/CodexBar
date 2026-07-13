import CodexBarCore
import Foundation
import Testing

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
        for (index, age) in [30.0, 20.0, 10.0].enumerated() {
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
    }
}
