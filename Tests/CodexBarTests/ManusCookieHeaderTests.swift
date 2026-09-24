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
}
