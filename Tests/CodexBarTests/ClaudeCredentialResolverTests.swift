@testable import CodexBarCore
import Foundation
import Testing

struct ClaudeCredentialResolverTests {
    @Test
    func `raw oauth token resolves to itself without refresh`() async throws {
        let token = try await ClaudeCredentialResolver.resolveAccessToken(
            from: .oauthToken("sk-ant-oat-static"))
        #expect(token == "sk-ant-oat-static")
    }

    @Test
    func `environment source reads from the given environment`() async throws {
        let token = try await ClaudeCredentialResolver.resolveAccessToken(
            from: .environment(key: "MY_CLAUDE_TOKEN"),
            environment: ["MY_CLAUDE_TOKEN": "sk-ant-oat-env"])
        #expect(token == "sk-ant-oat-env")
    }

    @Test
    func `missing environment variable throws`() async {
        await #expect(throws: (any Error).self) {
            _ = try await ClaudeCredentialResolver.resolveAccessToken(
                from: .environment(key: "ABSENT_TOKEN"),
                environment: [:])
        }
    }

    @Test
    func `reads a credentials file in the claudeAiOauth shape`() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("cb-creds-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: url) }
        let future = Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let json = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat-file","refreshToken":"rt-1",\
        "expiresAt":\(future),"scopes":["user:profile"]}}
        """
        try Data(json.utf8).write(to: url)

        let creds = try ClaudeCredentialResolver.readCredentialsFile(path: url.path)
        #expect(creds.accessToken == "sk-ant-oat-file")
        #expect(creds.refreshToken == "rt-1")
        #expect(creds.isExpired == false)
    }

    @Test
    func `encoded credentials round-trip through parse`() throws {
        let original = ClaudeOAuthCredentials(
            accessToken: "sk-ant-oat-rt",
            refreshToken: "rt-2",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            scopes: ["user:profile", "user:inference"],
            rateLimitTier: "tier-x",
            subscriptionType: "max")
        let data = try ClaudeCredentialResolver.encodeCredentialsJSON(original)
        let parsed = try ClaudeOAuthCredentials.parse(data: data)
        #expect(parsed.accessToken == original.accessToken)
        #expect(parsed.refreshToken == original.refreshToken)
        #expect(parsed.scopes == original.scopes)
        #expect(Int(parsed.expiresAt?.timeIntervalSince1970 ?? 0) == 1_800_000_000)
    }

    @Test
    func `write-back targets only secondary sources`() {
        #expect(ClaudeCredentialResolver.shouldPersist(
            to: .keychainService(service: "Claude Code-credentials", account: nil)) == false)
        #expect(ClaudeCredentialResolver.shouldPersist(
            to: .keychainService(service: "Claude Code-credentials-deadbeef", account: nil)) == true)
        #expect(ClaudeCredentialResolver.shouldPersist(
            to: .credentialsFile(path: "/x/.credentials.json")) == true)
        #expect(ClaudeCredentialResolver.shouldPersist(to: .oauthToken("x")) == false)
    }
}
