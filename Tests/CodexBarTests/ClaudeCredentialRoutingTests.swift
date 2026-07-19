import CodexBarCore
import Testing

struct ClaudeCredentialRoutingTests {
    @Test
    func `resolves raw OAuth token`() {
        let routing = ClaudeCredentialRouting.resolve(
            tokenAccountToken: "sk-ant-oat-test-token",
            manualCookieHeader: nil)

        #expect(routing == .oauth(accessToken: "sk-ant-oat-test-token"))
    }

    @Test
    func `resolves bearer OAuth token`() {
        let routing = ClaudeCredentialRouting.resolve(
            tokenAccountToken: "Bearer sk-ant-oat-test-token",
            manualCookieHeader: nil)

        #expect(routing == .oauth(accessToken: "sk-ant-oat-test-token"))
    }

    @Test
    func `resolves session token to cookie header`() {
        let routing = ClaudeCredentialRouting.resolve(
            tokenAccountToken: "sk-ant-session-token",
            manualCookieHeader: nil)

        #expect(routing == .webCookie(header: "sessionKey=sk-ant-session-token"))
    }

    @Test
    func `resolves config cookie header through shared normalizer`() {
        let routing = ClaudeCredentialRouting.resolve(
            tokenAccountToken: nil,
            manualCookieHeader: "Cookie: sessionKey=sk-ant-session-token; foo=bar")

        #expect(routing == .webCookie(header: "sessionKey=sk-ant-session-token; foo=bar"))
    }

    @Test
    func `token account input wins over config cookie fallback`() {
        let routing = ClaudeCredentialRouting.resolve(
            tokenAccountToken: "Bearer sk-ant-oat-test-token",
            manualCookieHeader: "Cookie: sessionKey=sk-ant-session-token")

        #expect(routing == .oauth(accessToken: "sk-ant-oat-test-token"))
    }

    @Test
    func `empty inputs resolve to none`() {
        let routing = ClaudeCredentialRouting.resolve(
            tokenAccountToken: "   ",
            manualCookieHeader: "\n")

        #expect(routing == .none)
    }
}
