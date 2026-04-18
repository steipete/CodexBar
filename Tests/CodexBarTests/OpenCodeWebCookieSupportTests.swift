import Testing
@testable import CodexBarCore

struct OpenCodeWebCookieSupportTests {
    @Test
    func `request cookie header keeps only opencode auth cookies`() {
        let header = OpenCodeWebCookieSupport.requestCookieHeader(
            from: "provider=google; auth=session123; theme=dark; __Host-auth=host456")

        #expect(header == "auth=session123; __Host-auth=host456")
    }

    @Test
    func `request cookie header returns nil when auth cookie is missing`() {
        let header = OpenCodeWebCookieSupport.requestCookieHeader(from: "provider=google; theme=dark")

        #expect(header == nil)
    }
}
