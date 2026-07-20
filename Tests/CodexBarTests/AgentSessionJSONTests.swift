import CodexBarCore
import Foundation
import Testing

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
}
