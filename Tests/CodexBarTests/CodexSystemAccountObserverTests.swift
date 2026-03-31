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

    @Test
    func `observer prefers cached authoritative workspace label over weak jwt label`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: cacheURL)
        }

        try Self.writeCodexAuthFile(
            homeURL: home,
            email: "user@example.com",
            plan: "team",
            accountId: "TEAM-123",
            workspaceTitle: "Personal")

        try CodexOpenAIWorkspaceIdentityCache.withFileURLOverrideForTesting(cacheURL) {
            try CodexOpenAIWorkspaceIdentityCache().store(
                CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "team-123",
                    workspaceLabel: "IDconcepts"))

            let observer = DefaultCodexSystemAccountObserver()
            let account = try observer.loadSystemAccount(environment: ["CODEX_HOME": home.path])

            #expect(account?.workspaceAccountID == "team-123")
            #expect(account?.workspaceLabel == "IDconcepts")
        }
    }

    private static func writeCodexAuthFile(
        homeURL: URL,
        email: String,
        plan: String,
        accountId: String? = nil,
        workspaceTitle: String? = nil) throws
    {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        var tokens: [String: Any] = [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": Self.fakeJWT(email: email, plan: plan, workspaceTitle: workspaceTitle),
        ]
        if let accountId {
            tokens["account_id"] = accountId
        }
        let auth = ["tokens": tokens]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String, workspaceTitle: String? = nil) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        var payload: [String: Any] = [
            "email": email,
            "chatgpt_plan_type": plan,
        ]
        if let workspaceTitle {
            payload["https://api.openai.com/auth"] = [
                "organizations": [
                    [
                        "title": workspaceTitle,
                        "is_default": true,
                    ],
                ],
            ]
        }
        let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payloadData))."
    }
}
