import Foundation
import Testing
@testable import CodexBarCore

struct CurlCaptureParserTests {
    @Test
    func `extracts request URL from standard DevTools capture`() {
        let curl = "curl 'https://example.com/api/usage' -H 'Authorization: Bearer fake-token'"
        #expect(CurlCaptureParser.requestURL(from: curl)?.absoluteString == "https://example.com/api/usage")
    }

    @Test
    func `extracts request URL from double quoted and bare captures`() {
        #expect(CurlCaptureParser.requestURL(from: "curl \"https://example.com/double\"")?.path == "/double")
        #expect(CurlCaptureParser.requestURL(from: "curl https://example.com/bare")?.path == "/bare")
    }

    @Test
    func `request URL returns nil for option first or malformed captures`() {
        #expect(CurlCaptureParser.requestURL(from: "curl --location 'https://example.com'") == nil)
        #expect(CurlCaptureParser.requestURL(from: "not-curl 'https://example.com'") == nil)
    }

    @Test
    func `extracts header fields from double quoted headers`() {
        let curl = """
        curl 'https://example.com' --header "Authorization: Bearer fake-token" --header "Cookie: session=abc"
        """
        let fields = CurlCaptureParser.headerFields(from: curl)

        #expect(fields.contains("Authorization: Bearer fake-token"))
        #expect(fields.contains("Cookie: session=abc"))
    }

    @Test
    func `extracts header fields from single quoted -H flags`() {
        let curl = "curl 'https://example.com' -H 'Authorization: Bearer fake-token'"
        let fields = CurlCaptureParser.headerFields(from: curl)

        #expect(fields == ["Authorization: Bearer fake-token"])
    }

    @Test
    func `header value lookup is case insensitive`() {
        let fields = ["AUTHORIZATION: Bearer fake-token"]
        #expect(CurlCaptureParser.headerValue(named: "authorization", in: fields) == "Bearer fake-token")
    }

    @Test
    func `header value lookup returns nil for missing header`() {
        let fields = ["Cookie: session=abc"]
        #expect(CurlCaptureParser.headerValue(named: "Authorization", in: fields) == nil)
    }

    @Test
    func `forwarded headers respects allowlist and drops unlisted headers`() {
        let fields = [
            "Authorization: Bearer fake-token",
            "Cookie: session=abc",
            "X-Not-Allowed: nope",
        ]
        let allowlist = ["authorization": "Authorization", "cookie": "Cookie"]
        let headers = CurlCaptureParser.forwardedHeaders(from: fields, allowlist: allowlist)

        #expect(headers["Authorization"] == "Bearer fake-token")
        #expect(headers["Cookie"] == "session=abc")
        #expect(headers["X-Not-Allowed"] == nil)
    }

    @Test
    func `forwarded headers can include authorization when allowlisted`() {
        // ZoomMate's allowlist differs from T3 Chat's by deliberately including authorization (design D2).
        let fields = ["authorization: Bearer fake-token"]
        let allowlist = ["authorization": "Authorization"]
        let headers = CurlCaptureParser.forwardedHeaders(from: fields, allowlist: allowlist)

        #expect(headers["Authorization"] == "Bearer fake-token")
    }
}
