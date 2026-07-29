import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import SweetCookieKit

struct ZoomMateCookieScopeTests {
    @Test
    func `automatic import recovers chromium scope before partitioning cookies`() {
        let records = [
            Self.cookieRecord(domain: "zoom.us", name: "parent"),
            Self.cookieRecord(domain: "zoom.us", name: "root-host-only"),
            Self.cookieRecord(domain: "ai.zoom.us", name: "ai-only"),
            Self.cookieRecord(domain: "zoommate.zoom.us", name: "mate-only"),
        ]
        let metadata = [
            Self.cookieMetadata(hostKey: ".zoom.us", name: "parent"),
            Self.cookieMetadata(hostKey: "zoom.us", name: "root-host-only"),
            Self.cookieMetadata(hostKey: "ai.zoom.us", name: "ai-only"),
            Self.cookieMetadata(hostKey: "zoommate.zoom.us", name: "mate-only"),
        ]

        let cookies = ZoomMateChromiumCookieScopeReader.resolve(records: records, metadata: metadata)
        let headers = ZoomMateCookieImporter.cookieHeaders(from: cookies)

        #expect(headers.header(forHost: "ai.zoom.us") == "parent=fake; ai-only=fake")
        #expect(headers.header(forHost: "zoommate.zoom.us") == "parent=fake; mate-only=fake")
    }

    @Test
    func `cookie scope filter follows RFC 6265 host-only and domain matching`() {
        #expect(Self.isSendable(domain: "ai.zoom.us", hostOnly: true, to: "ai.zoom.us"))
        #expect(!Self.isSendable(domain: "ai.zoom.us", hostOnly: true, to: "zoommate.zoom.us"))
        #expect(Self.isSendable(domain: "zoom.us", hostOnly: false, to: "ai.zoom.us"))
        #expect(Self.isSendable(domain: "zoom.us", hostOnly: false, to: "zoommate.zoom.us"))
        #expect(!Self.isSendable(domain: "zoom.us", hostOnly: true, to: "ai.zoom.us"))
        #expect(!Self.isSendable(domain: "zoom.us", hostOnly: true, to: "zoommate.zoom.us"))
        #expect(!Self.isSendable(domain: "marketing.zoom.us", hostOnly: false, to: "ai.zoom.us"))
        #expect(!Self.isSendable(domain: "zoom.us.attacker.com", hostOnly: false, to: "ai.zoom.us"))
        #expect(!Self.isSendable(domain: "", hostOnly: false, to: "ai.zoom.us"))
        #expect(!Self.isSendable(domain: "zoom.us", hostOnly: false, path: "/login", to: "ai.zoom.us"))
    }

    @Test
    func `scope recovery drops ambiguous missing and partitioned records`() {
        let records = [
            Self.cookieRecord(domain: "zoom.us", name: "ambiguous"),
            Self.cookieRecord(domain: "zoom.us", name: "missing"),
            Self.cookieRecord(domain: "zoom.us", name: "partitioned"),
            Self.cookieRecord(domain: "zoom.us", name: "parent"),
        ]
        let metadata = [
            Self.cookieMetadata(hostKey: ".zoom.us", name: "ambiguous"),
            Self.cookieMetadata(hostKey: "zoom.us", name: "ambiguous"),
            Self.cookieMetadata(
                hostKey: ".zoom.us",
                topFrameSiteKey: "https://example.com",
                name: "partitioned"),
            Self.cookieMetadata(hostKey: ".zoom.us", name: "parent"),
        ]
        var messages: [String] = []

        let cookies = ZoomMateChromiumCookieScopeReader.resolve(
            records: records,
            metadata: metadata,
            logger: { messages.append($0) })

        #expect(cookies.map(\.record.name) == ["parent"])
        #expect(cookies.first?.scope == .domain)
        #expect(messages.contains { $0.contains("missing: 1") })
        #expect(messages.contains { $0.contains("ambiguous scope: 1") })
        #expect(messages.contains { $0.contains("partitioned: 1") })
    }

    private static func cookieRecord(
        domain: String,
        name: String,
        value: String = "fake",
        path: String = "/") -> BrowserCookieRecord
    {
        BrowserCookieRecord(
            domain: domain,
            name: name,
            path: path,
            value: value,
            expires: Date(timeIntervalSince1970: 1_900_000_000),
            isSecure: true,
            isHTTPOnly: true)
    }

    private static func cookieMetadata(
        hostKey: String,
        topFrameSiteKey: String = "",
        name: String,
        path: String = "/") -> ZoomMateChromiumCookieScopeReader.CookieMetadata
    {
        ZoomMateChromiumCookieScopeReader.CookieMetadata(
            hostKey: hostKey,
            topFrameSiteKey: topFrameSiteKey,
            name: name,
            path: path)
    }

    private static func isSendable(
        domain: String,
        hostOnly: Bool,
        path: String = "/",
        to host: String) -> Bool
    {
        ZoomMateCookieImporter.isSendable(
            cookieDomain: domain,
            hostOnly: hostOnly,
            path: path,
            toHost: host)
    }
}
#endif
