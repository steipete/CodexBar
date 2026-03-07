import CodexBarCore
import Testing

@Suite
struct ClaudeCredentialRoutingTests {
    @Test
    func resolvesRawOAuthToken() {
        let routing = ClaudeCredentialRouting.resolve(
            tokenAccountToken: "sk-ant-oat-test-token",
            manualCookieHeader: nil)

        #expect(routing == .oauth(accessToken: "sk-ant-oat-test-token"))
    }

    @Test
    func resolvesBearerOAuthToken() {
        let routing = ClaudeCredentialRouting.resolve(
            tokenAccountToken: "Bearer sk-ant-oat-test-token",
            manualCookieHeader: nil)

        #expect(routing == .oauth(accessToken: "sk-ant-oat-test-token"))
    }

    @Test
    func resolvesSessionTokenToCookieHeader() {
        let routing = ClaudeCredentialRouting.resolve(
            tokenAccountToken: "sk-ant-session-token",
            manualCookieHeader: nil)

        #expect(routing == .webCookie(header: "sessionKey=sk-ant-session-token"))
    }

    @Test
    func resolvesConfigCookieHeaderThroughSharedNormalizer() {
        let routing = ClaudeCredentialRouting.resolve(
            tokenAccountToken: nil,
            manualCookieHeader: "Cookie: sessionKey=sk-ant-session-token; foo=bar")

        #expect(routing == .webCookie(header: "sessionKey=sk-ant-session-token; foo=bar"))
    }

    @Test
    func tokenAccountInputWinsOverConfigCookieFallback() {
        let routing = ClaudeCredentialRouting.resolve(
            tokenAccountToken: "Bearer sk-ant-oat-test-token",
            manualCookieHeader: "Cookie: sessionKey=sk-ant-session-token")

        #expect(routing == .oauth(accessToken: "sk-ant-oat-test-token"))
    }

    @Test
    func emptyInputsResolveToNone() {
        let routing = ClaudeCredentialRouting.resolve(
            tokenAccountToken: "   ",
            manualCookieHeader: "\n")

        #expect(routing == .none)
    }
}
