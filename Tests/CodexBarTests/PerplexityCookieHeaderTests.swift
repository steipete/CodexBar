import Testing
@testable import CodexBarCore

@Suite
struct PerplexityCookieHeaderTests {
    @Test
    func bareTokenUsesDefaultSessionCookieName() {
        let override = PerplexityCookieHeader.override(from: "abc123")
        #expect(override?.name == PerplexityCookieHeader.defaultSessionCookieName)
        #expect(override?.token == "abc123")
    }

    @Test
    func extractsSecureNextAuthSessionCookieFromHeader() {
        let header = "foo=bar; __Secure-next-auth.session-token=token-a; baz=qux"
        let override = PerplexityCookieHeader.override(from: header)
        #expect(override?.name == "__Secure-next-auth.session-token")
        #expect(override?.token == "token-a")
    }

    @Test
    func extractsAuthJSSessionCookieFromHeader() {
        let header = "foo=bar; __Secure-authjs.session-token=token-b; baz=qux"
        let override = PerplexityCookieHeader.override(from: header)
        #expect(override?.name == "__Secure-authjs.session-token")
        #expect(override?.token == "token-b")
    }

    @Test
    func unsupportedCookieHeaderReturnsNil() {
        let override = PerplexityCookieHeader.override(from: "foo=bar; hello=world")
        #expect(override == nil)
    }
}
