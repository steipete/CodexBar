import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct AgentSessionJSONTests {
    @Test
    func `sessions json round trip preserves stable schema`() throws {
        let session = AgentSession(
            id: "fixture-session",
            provider: .codex,
            source: .ide,
            state: .active,
            pid: 42,
            cwd: "/tmp/project",
            projectName: "project",
            sessionName: "Fix session labels",
            startedAt: Date(timeIntervalSince1970: 100),
            lastActivityAt: Date(timeIntervalSince1970: 200),
            transcriptPath: "/tmp/rollout.jsonl",
            host: "local-mac")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([session])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let keys = try #require(object.first).keys
        #expect(Set(keys) == [
            "id", "provider", "source", "state", "pid", "cwd", "projectName", "sessionName", "startedAt",
            "lastActivityAt", "transcriptPath", "host",
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode([AgentSession].self, from: data) == [session])

        var legacyObject = try #require(object.first)
        legacyObject.removeValue(forKey: "sessionName")
        let legacyData = try JSONSerialization.data(withJSONObject: [legacyObject])
        let legacySession = try #require(decoder.decode([AgentSession].self, from: legacyData).first)
        #expect(legacySession.sessionName == nil)
        #expect(legacySession.id == session.id)
    }

    @Test
    func `legacy v1 JSON excludes OhMyPi and remains decodable by closed provider clients`() throws {
        let sessions = self.makeProtocolFixture()
        let legacySessions = CodexBarCLI.sessionsForJSON(sessions, includeOhMyPi: false)
        #expect(legacySessions.map(\.provider) == [.codex, .claude])

        let legacyData = try self.encode(legacySessions)
        let decoded = try JSONDecoder().decode([LegacyAgentSession].self, from: legacyData)
        #expect(decoded.map(\.provider) == [.codex, .claude])
    }

    @Test
    func `v2 JSON includes OhMyPi and remains the same array shape`() throws {
        let sessions = self.makeProtocolFixture()
        let v2Sessions = CodexBarCLI.sessionsForJSON(sessions, includeOhMyPi: true)
        let v2Data = try self.encode(v2Sessions)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([AgentSession].self, from: v2Data)

        #expect(decoded == sessions)
        #expect(decoded.contains { $0.provider == .ohMyPi })
    }

    @Test
    func `json flags select their protocol versions`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(SessionsOptions()))
        let legacyParsed = try parser.parse(arguments: ["--json"])
        #expect(CodexBarCLI.sessionsJSONProtocolVersion(from: legacyParsed) == 1)

        let v2Parsed = try parser.parse(arguments: ["--json-v2"])
        #expect(v2Parsed.flags.contains("jsonV2"))
        #expect(CodexBarCLI.sessionsJSONProtocolVersion(from: v2Parsed) == 2)
        #expect(CodexBarCLI.sessionsForJSON(
            self.makeProtocolFixture(),
            includeOhMyPi: CodexBarCLI.sessionsJSONProtocolVersion(from: v2Parsed) == 2)
            .contains { $0.provider == .ohMyPi })
    }

    @Test
    func `human-readable sessions table still includes OhMyPi`() {
        #expect(CodexBarCLI.renderSessionsTable(self.makeProtocolFixture()).contains("oh-my-pi"))
    }

    private func makeProtocolFixture() -> [AgentSession] {
        [
            self.makeSession(id: "codex-session", provider: .codex),
            self.makeSession(id: "claude-session", provider: .claude),
            self.makeSession(id: "omp-session", provider: .ohMyPi),
        ]
    }

    private func makeSession(id: String, provider: AgentSession.Provider) -> AgentSession {
        AgentSession(
            id: id,
            provider: provider,
            source: .cli,
            state: .active,
            pid: 42,
            cwd: "/tmp/project",
            projectName: "project",
            startedAt: Date(timeIntervalSince1970: 100),
            lastActivityAt: Date(timeIntervalSince1970: 200),
            transcriptPath: nil,
            host: "local-mac")
    }

    private func encode(_ sessions: [AgentSession]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(sessions)
    }
}

private struct LegacyAgentSession: Decodable {
    enum Provider: String, Decodable {
        case codex
        case claude
    }

    let provider: Provider

    private enum CodingKeys: String, CodingKey {
        case provider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decode(Provider.self, forKey: .provider)
    }
}
