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
        #expect(OpenCodeWebCookieSupport.requestCookieHeader(from: "console_session=unverified") == nil)
    }

    /// The console signs its own requests, so its session cookie has to survive the filter.
    @Test
    func `request cookie header keeps the console session cookie`() {
        let header = OpenCodeWebCookieSupport.requestCookieHeader(
            from: "oc_locale=en; auth=session123; __Host-console_session=console456; __stripe_mid=x")

        #expect(header == "auth=session123; __Host-console_session=console456")
    }

    /// A fully migrated workspace can carry the console cookie alone.
    @Test
    func `request cookie header accepts a console-only session`() {
        let header = OpenCodeWebCookieSupport.requestCookieHeader(
            from: "oc_locale=en; __Host-console_session=console456")

        #expect(header == "__Host-console_session=console456")
    }
}
