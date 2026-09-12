import CodexBarCore
import Foundation
import Testing

struct AgentSessionParserTests {
    @Test
    func `ps parser deduplicates desktop wrapper and excludes app server and helpers`() throws {
        let output = try Self.fixtureString("agent-sessions-ps", extension: "txt")
        let records = AgentPSOutputParser.parse(output)
        let agents = AgentPSOutputParser.agentProcesses(from: records)

        #expect(records.count == 18)
        #expect(agents.map(\ .pid) == [102, 201, 501, 502, 509])
        #expect(AgentPSOutputParser.provider(for: agents[0]) == .claude)
        #expect(AgentPSOutputParser.source(for: agents[0]) == .desktopApp)
        #expect(AgentPSOutputParser.provider(for: agents[1]) == .codex)
        #expect(agents[1].command.hasSuffix("strange argv here"))
        #expect(AgentPSOutputParser.hasCodexAppServer(in: records))
        #expect(AgentPSOutputParser.provider(for: agents[2]) == .pi)
        #expect(AgentPSOutputParser.piDialect(for: agents[2]) == .omp)
        #expect(AgentPSOutputParser.source(for: agents[2]) == .cli)
        #expect(AgentPSOutputParser.provider(for: agents[3]) == .pi)
        #expect(AgentPSOutputParser.piDialect(for: agents[3]) == .omp)
        #expect(AgentPSOutputParser.source(for: agents[3]) == .cli)
        #expect(AgentPSOutputParser.provider(for: agents[4]) == .pi)
        #expect(AgentPSOutputParser.piDialect(for: agents[4]) == .pi)
        let unrelatedBun = try #require(records.first { $0.pid == 507 })
        let unrelatedNpm = try #require(records.first { $0.pid == 508 })
        #expect(AgentPSOutputParser.provider(for: unrelatedBun) == nil)
        #expect(AgentPSOutputParser.provider(for: unrelatedNpm) == nil)
        for helperPID in [503, 504, 505, 506] {
            let helper = try #require(records.first { $0.pid == helperPID })
            #expect(AgentPSOutputParser.provider(for: helper) == nil)
            #expect(AgentPSOutputParser.source(for: helper) == .cli)
        }
    }

    @Test
    func `chatgpt bundled codex app server is recognized without becoming a live agent`() {
        let records = AgentPSOutputParser.parse("""
        4234 1 Mon Jul 6 09:03:00 2026 /Applications/ChatGPT.app/Contents/Resources/codex \
        -c features.code_mode_host=true app-server --analytics-default-enabled
        20409 1 Mon Jul 6 09:04:00 2026 /Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host
        """)

        #expect(records.count == 2)
        #expect(AgentPSOutputParser.agentProcesses(from: records).isEmpty)
        #expect(AgentPSOutputParser.hasCodexAppServer(in: records))
    }

    @Test
    func `pi dialects use stable Codable raw values`() throws {
        let provider = try JSONEncoder().encode(AgentSession.Provider.pi)
        let dialects = try JSONEncoder().encode([AgentSession.Dialect.pi, .omp])

        #expect(String(data: provider, encoding: .utf8) == "\"pi\"")
        #expect(String(data: dialects, encoding: .utf8) == "[\"pi\",\"omp\"]")
        #expect(try JSONDecoder().decode(AgentSession.Provider.self, from: provider) == .pi)
    }

    @Test
    func `lsof parser maps batched cwd records`() throws {
        let output = try Self.fixtureString("agent-sessions-lsof", extension: "txt")
        let paths = LSOFCWDOutputParser.parse(output)

        #expect(paths[102] == "/Users/test/Projects/alpha")
        #expect(paths[201] == "/Users/test/Projects/project with spaces")
    }

    @Test
    func `same cwd processes remain uncorrelated when ownership is ambiguous`() {
        let olderStart = Date(timeIntervalSince1970: 100)
        let newerStart = Date(timeIntervalSince1970: 200)
        let older = AgentProcessRecord(pid: 10, ppid: 1, startedAt: olderStart, command: "claude")
        let newer = AgentProcessRecord(pid: 20, ppid: 1, startedAt: newerStart, command: "claude")
        let olderTranscript = ClaudeSessionProjectMapper.Transcript(
            url: URL(fileURLWithPath: "/tmp/older.jsonl"),
            modifiedAt: Date(timeIntervalSince1970: 150))
        let newerTranscript = ClaudeSessionProjectMapper.Transcript(
            url: URL(fileURLWithPath: "/tmp/newer.jsonl"),
            modifiedAt: Date(timeIntervalSince1970: 250))

        let assignments = AgentSessionCorrelation.assignClaudeTranscripts(
            processes: [older, newer],
            cwdByPID: [10: "/project", 20: "/project"],
            transcriptsByCWD: ["/project": [newerTranscript, olderTranscript]])

        #expect(assignments.isEmpty)
    }

    @Test
    func `newest process sorts first for rollout correlation`() {
        let older = AgentProcessRecord(
            pid: 10,
            ppid: 1,
            startedAt: Date(timeIntervalSince1970: 100),
            command: "codex exec")
        let newer = AgentProcessRecord(
            pid: 20,
            ppid: 1,
            startedAt: Date(timeIntervalSince1970: 200),
            command: "codex exec")

        #expect(AgentSessionCorrelation.newestProcessesFirst([older, newer]).map(\ .pid) == [20, 10])
    }

    static func fixtureURL(_ name: String, extension fileExtension: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures"))
    }

    static func fixtureString(_ name: String, extension fileExtension: String) throws -> String {
        try String(contentsOf: self.fixtureURL(name, extension: fileExtension), encoding: .utf8)
    }
}
