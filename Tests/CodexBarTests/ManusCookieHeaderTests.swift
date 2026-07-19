import Foundation
import Testing
@testable import CodexBarCore

struct ManusCookieHeaderTests {
    @Test
    func `bare token resolves directly`() {
        #expect(ManusCookieHeader.token(from: "abc123") == "abc123")
    }

    @Test
    func `extracts session_id from cookie header`() {
        let header = "foo=bar; session_id=token-a; baz=qux"
        #expect(ManusCookieHeader.token(from: header) == "token-a")
    }

    @Test
    func `extracts mixed case session id from cookie header`() {
        let header = "foo=bar; Session_ID=token-b; baz=qux"
        #expect(ManusCookieHeader.token(from: header) == "token-b")
    }

    @Test
    func `unsupported cookie header returns nil`() {
        #expect(ManusCookieHeader.token(from: "foo=bar; hello=world") == nil)
    }

    #if os(macOS)
    @Test
    func `importer session info extracts session token`() throws {
        let cookies = try [
            #require(self.makeCookie(name: "session_id", value: "cookie-token")),
        ]
        let session = ManusCookieImporter.SessionInfo(cookies: cookies, sourceLabel: "Chrome")
        #expect(session.sessionToken == "cookie-token")
    }

    private func makeCookie(name: String, value: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .domain: "manus.im",
            .path: "/",
            .name: name,
            .value: value,
            .secure: "TRUE",
        ])
    }
    #endif
}
