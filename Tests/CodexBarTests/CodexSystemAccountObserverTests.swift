import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct CodexSystemAccountObserverTests {
    @Test
    func `observer reads ambient CODEX_HOME when present`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.writeCodexAuthFile(homeURL: home, email: "  LIVE@Example.com  ", plan: "pro")

        let observer = DefaultCodexSystemAccountObserver()
        let account = try observer.loadSystemAccount(environment: ["CODEX_HOME": home.path])

        #expect(account?.email == "live@example.com")
        #expect(account?.codexHomePath == home.path)
    }

    @Test
    func `observer falls back to nil when ambient home has no readable email`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let observer = DefaultCodexSystemAccountObserver()
        let account = try observer.loadSystemAccount(environment: ["CODEX_HOME": home.path])

        #expect(account == nil)
    }

    @Test
    func `observer records observation timestamp`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.writeCodexAuthFile(homeURL: home, email: "user@example.com", plan: "team")

        let before = Date()
        let observer = DefaultCodexSystemAccountObserver()
        let account = try observer.loadSystemAccount(environment: ["CODEX_HOME": home.path])
        let observed = try #require(account)

        #expect(observed.observedAt >= before)
    }

    private static func writeCodexAuthFile(homeURL: URL, email: String, plan: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let auth = [
            "tokens": [
                "accessToken": "access-token",
                "refreshToken": "refresh-token",
                "idToken": Self.fakeJWT(email: email, plan: plan),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
        ])) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}
