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
    func `legacy v1 JSON excludes Pi-family sessions and remains decodable by closed provider clients`() throws {
        let sessions = self.makeProtocolFixture()
        let legacySessions = CodexBarCLI.sessionsForJSON(sessions, includePiFamily: false)
        #expect(legacySessions.map(\.provider) == [.codex, .claude])

        let legacyData = try self.encode(legacySessions)
        let decoded = try JSONDecoder().decode([LegacyAgentSession].self, from: legacyData)
        #expect(decoded.map(\.provider) == [.codex, .claude])
    }

    @Test
    func `versioned JSON flags preserve legacy compatibility and expose Pi-family sessions only in v2`() throws {
        let sessions = self.makeProtocolFixture()
        let parser = CommandParser(signature: CommandSignature.describe(SessionsOptions()))
        let expectations = [
            (flag: "--json", version: 1, includesPiFamily: false),
            (flag: "--json-v2", version: 2, includesPiFamily: true),
        ]

        for expectation in expectations {
            let parsed = try parser.parse(arguments: [expectation.flag])
            let protocolVersion = CodexBarCLI.sessionsJSONProtocolVersion(from: parsed)
            #expect(protocolVersion == expectation.version)

            let currentSessions = CodexBarCLI.sessionsForJSON(
                sessions,
                includePiFamily: protocolVersion == 2)
            let currentData = try self.encode(currentSessions)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([AgentSession].self, from: currentData)

            #expect(decoded == (expectation.includesPiFamily ? sessions : sessions.filter { $0.provider != .pi }))
            #expect(decoded.contains { $0.provider == .pi } == expectation.includesPiFamily)
        }
    }

    @Test
    func `mixed-version clients decode the repaired protocol in both upgrade directions`() throws {
        let sessions = self.makeProtocolFixture()
        let parser = CommandParser(signature: CommandSignature.describe(SessionsOptions()))
        let newHostLegacyFlag = try parser.parse(arguments: ["--json"])
        #expect(CodexBarCLI.sessionsJSONProtocolVersion(from: newHostLegacyFlag) == 1)

        // A new host answering an old client keeps Pi-family rows out of the legacy payload.
        let newHostLegacySessions = CodexBarCLI.sessionsForJSON(sessions, includePiFamily: false)
        let newHostLegacyData = try self.encode(newHostLegacySessions)
        let oldClientSessions = try JSONDecoder().decode([LegacyAgentSession].self, from: newHostLegacyData)
        #expect(oldClientSessions.map(\.provider) == [.codex, .claude])

        // A new client falling back to an old host can decode that same v1 payload.
        let oldHostLegacyData = try self.encode(sessions.filter { $0.provider != .pi })
        let newClientDecoder = JSONDecoder()
        newClientDecoder.dateDecodingStrategy = .iso8601
        let newClientSessions = try newClientDecoder.decode([AgentSession].self, from: oldHostLegacyData)
        #expect(newClientSessions == newHostLegacySessions)
    }

    @Test
    func `human-readable sessions table includes Pi-family dialect tags`() {
        let table = CodexBarCLI.renderSessionsTable(self.makeProtocolFixture())
        #expect(table.contains("DIALECT"))
        #expect(table.contains("omp"))
    }

    private func makeProtocolFixture() -> [AgentSession] {
        [
            self.makeSession(id: "codex-session", provider: .codex),
            self.makeSession(id: "claude-session", provider: .claude),
            self.makeSession(id: "omp-session", provider: .pi, dialect: .omp),
        ]
    }

    private func makeSession(
        id: String,
        provider: AgentSession.Provider,
        dialect: AgentSession.Dialect? = nil) -> AgentSession
    {
        AgentSession(
            id: id,
            provider: provider,
            dialect: dialect,
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
