import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import SweetCookieKit

struct MuseCookieImporterTests {
    @Test
    func `uses an explicitly selected browser instead of prompting the automatic first candidate`() {
        #expect(MuseCookieImporter.preferredBrowsers(for: .auto) == nil)
        #expect(MuseCookieImporter.preferredBrowsers(for: .chrome) == [.chrome])
        #expect(MuseCookieImporter.preferredBrowsers(for: .brave) == [.brave])
        #expect(MuseCookieImporter.resolvedImportOrder([.brave]) == [.brave])
    }

    // MARK: - Helpers

    private func makeCookie(
        domain: String,
        path: String = "/",
        name: String = "test",
        value: String = "v",
        isSecure: Bool = false,
        expires: Date? = Date(timeIntervalSinceNow: 3600)) throws -> HTTPCookie
    {
        var props: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value,
        ]
        if let e = expires { props[.expires] = e }
        if isSecure { props[.secure] = true }
        return try #require(HTTPCookie(properties: props))
    }

    // MARK: - P2: Chrome + Brave default (Chrome preferred, Brave fallback)

    @Test
    func `muse automatic cookie import tries chrome then brave`() {
        #expect(ProviderDefaults.metadata[.muse]?.browserCookieOrder == [.chrome, .brave])
        #expect(MuseProviderDescriptor.descriptor.metadata.browserCookieOrder == [.chrome, .brave])
    }

    // MARK: - P1: Cookie isolation

    @Test
    func `filters unrelated facebook cookie for dev meta ai destination`() throws {
        let devCookie = try makeCookie(domain: "dev.meta.ai", name: "llm_sess", value: "abc123")
        let fbUnrelated = try makeCookie(domain: "facebook.com", name: "fr", value: "unrelated")
        let fbSession = try makeCookie(domain: "facebook.com", name: "c_user", value: "999")
        let all = [devCookie, fbUnrelated, fbSession]

        let filtered = MuseCookieImporter.filteredCookiesForDestination(all, at: MuseCookieImporter.destinationURL)

        #expect(filtered.contains(where: { $0.name == "llm_sess" }))
        #expect(!filtered.contains(where: { $0.name == "fr" }))
        #expect(!filtered.contains(where: { $0.name == "c_user" }))
        // All facebook.com cookies are filtered — browser would not attach them to dev.meta.ai
    }

    @Test
    func `keeps meta ai suffix cookies`() throws {
        let meta = try makeCookie(domain: "meta.ai", name: "datr", value: "x")
        let filtered = MuseCookieImporter.filteredCookiesForDestination([meta], at: MuseCookieImporter.destinationURL)
        #expect(filtered.contains(where: { $0.name == "datr" }))
    }

    @Test
    func `keeps dev meta ai exact domain`() throws {
        let exact = try makeCookie(domain: "dev.meta.ai", name: "sess", value: "1")
        let filtered = MuseCookieImporter.filteredCookiesForDestination([exact], at: MuseCookieImporter.destinationURL)
        #expect(filtered.count == 1)
    }

    @Test
    func `filters path mismatched cookie`() throws {
        let ok = try makeCookie(domain: "dev.meta.ai", path: "/", name: "a", value: "1")
        let mismatched = try makeCookie(domain: "dev.meta.ai", path: "/admin", name: "b", value: "2")
        let filtered = MuseCookieImporter.filteredCookiesForDestination(
            [ok, mismatched],
            at: MuseCookieImporter.destinationURL)
        #expect(filtered.contains(where: { $0.name == "a" }))
        #expect(!filtered.contains(where: { $0.name == "b" }))
    }

    @Test
    func `filters expired cookies`() throws {
        let expired = try makeCookie(
            domain: "dev.meta.ai",
            name: "old",
            value: "1",
            expires: Date(timeIntervalSinceNow: -3600))
        let live = try makeCookie(domain: "dev.meta.ai", name: "new", value: "2")
        let filtered = MuseCookieImporter.filteredCookiesForDestination(
            [expired, live],
            at: MuseCookieImporter.destinationURL)
        #expect(!filtered.contains(where: { $0.name == "old" }))
        #expect(filtered.contains(where: { $0.name == "new" }))
    }

    @Test
    func `filters empty value cookies`() throws {
        let empty = try makeCookie(domain: "dev.meta.ai", name: "empty", value: "")
        let filtered = MuseCookieImporter.filteredCookiesForDestination([empty], at: MuseCookieImporter.destinationURL)
        #expect(filtered.isEmpty)
    }

    @Test
    func `cookie header preserves only isolated cookies`() throws {
        let dev = try makeCookie(domain: "dev.meta.ai", name: "llm_sess", value: "ABC")
        let fb = try makeCookie(domain: "facebook.com", name: "fr", value: "FBFB")
        let filtered = MuseCookieImporter.filteredCookiesForDestination(
            [dev, fb],
            at: MuseCookieImporter.destinationURL)
        let header = filtered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        #expect(header.contains("llm_sess=ABC"))
        #expect(!header.contains("fr=FBFB"))
    }

    @Test
    func `recognizes current Muse browser session cookies`() throws {
        let llm = try makeCookie(domain: "dev.meta.ai", name: "llm_sess", value: "current")
        let ecto = try makeCookie(domain: "dev.meta.ai", name: "ecto_1_sess", value: "current")
        let unrelated = try makeCookie(domain: "dev.meta.ai", name: "datr", value: "not-auth")

        #expect(MuseCookieImporter.hasAuthenticatedSessionCookie([llm]))
        #expect(MuseCookieImporter.hasAuthenticatedSessionCookie([ecto]))
        #expect(!MuseCookieImporter.hasAuthenticatedSessionCookie([unrelated]))
    }

    @Test
    func `builds a chromium user agent from the selected browser major version`() {
        let userAgent = MuseCookieImporter.chromiumUserAgent(majorVersion: "152")
        #expect(userAgent.contains("Chrome/152.0.0.0"))
        #expect(!userAgent.contains("Brave"))
    }

    @Test
    func `hostOnly scope not sent to subdomain`() {
        #expect(!MuseCookieImporter.isSendable(cookieDomain: "meta.ai", scope: .hostOnly, toHost: "dev.meta.ai"))
        #expect(MuseCookieImporter.isSendable(cookieDomain: "meta.ai", scope: .domain, toHost: "dev.meta.ai"))
        #expect(MuseCookieImporter.isSendable(cookieDomain: "dev.meta.ai", scope: .hostOnly, toHost: "dev.meta.ai"))
        #expect(!MuseCookieImporter.isSendable(cookieDomain: "facebook.com", scope: .domain, toHost: "dev.meta.ai"))
        #expect(MuseCookieImporter.isSendable(cookieDomain: "dev.meta.ai", scope: .domain, toHost: "dev.meta.ai"))
    }
}
#else
struct MuseCookieImporterTests {
    @Test func `non mac OS placeholder`() {
        #expect(true)
    }
}
#endif
