import CodexBarCore
import Testing

struct ClaudeCredentialSourceTests {
    @Test
    func `legacy raw token stays raw and parses as oauthToken`() {
        let source = ClaudeCredentialSource.oauthToken("sk-ant-oat-abc")
        #expect(source.encodedTokenValue() == "sk-ant-oat-abc")
        #expect(ClaudeCredentialSource.parse("sk-ant-oat-abc") == .oauthToken("sk-ant-oat-abc"))
        #expect(source.isRefreshableSource == false)
    }

    @Test
    func `keychain source round-trips through encode and parse`() {
        let source = ClaudeCredentialSource.keychainService(
            service: "Claude Code-credentials-39eddfe1",
            account: "alice@example.com")
        let encoded = source.encodedTokenValue()
        #expect(encoded.hasPrefix(ClaudeCredentialSource.descriptorPrefix))
        #expect(ClaudeCredentialSource.parse(encoded) == source)
        #expect(source.isRefreshableSource)
    }

    @Test
    func `keychain source without account round-trips`() {
        let source = ClaudeCredentialSource.keychainService(
            service: "Claude Code-credentials",
            account: nil)
        #expect(ClaudeCredentialSource.parse(source.encodedTokenValue()) == source)
    }

    @Test
    func `file source round-trips and preserves a full path`() {
        let source = ClaudeCredentialSource.credentialsFile(
            path: "/Users/x/.claude-acct2/.credentials.json")
        #expect(ClaudeCredentialSource.parse(source.encodedTokenValue()) == source)
        #expect(source.isRefreshableSource)
    }

    @Test
    func `environment source round-trips`() {
        let source = ClaudeCredentialSource.environment(key: "CODEXBAR_CLAUDE_OAUTH_TOKEN")
        #expect(ClaudeCredentialSource.parse(source.encodedTokenValue()) == source)
    }

    @Test
    func `garbage descriptor falls back to a raw token`() {
        let raw = ClaudeCredentialSource.descriptorPrefix + "!!!not base64!!!"
        #expect(ClaudeCredentialSource.parse(raw) == .oauthToken(raw))
    }

    @Test
    func `display label prefers account, then config dir name`() {
        #expect(
            ClaudeCredentialSource.keychainService(service: "Svc", account: "bob@x.com")
                .displayLabel() == "bob@x.com")
        #expect(
            ClaudeCredentialSource.credentialsFile(path: "/Users/x/.claude-acct2/.credentials.json")
                .displayLabel() == ".claude-acct2")
    }
}
