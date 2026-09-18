import Foundation
import SweetCookieKit
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct HelmcodeCookieHeaderTests {
    @Test
    func `imported cookies honor request host path secure and expiry scope`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cookies = try [
            self.cookie(name: "root", value: "1", domain: ".helmcode.com", path: "/"),
            self.cookie(name: "api", value: "2", domain: "cloud-api.helmcode.com", path: "/api"),
            self.cookie(name: "dashboard", value: "3", domain: "cloud.helmcode.com", path: "/"),
            self.cookie(name: "wrongPath", value: "4", domain: "cloud-api.helmcode.com", path: "/settings"),
            self.cookie(
                name: "expired",
                value: "5",
                domain: "cloud-api.helmcode.com",
                path: "/",
                expires: now - 1),
            self.cookie(name: "secure", value: "6", domain: "cloud-api.helmcode.com", path: "/", secure: true),
        ]
        let secureURL = try #require(URL(string: "https://cloud-api.helmcode.com/api/usage/quota"))
        let insecureURL = try #require(URL(string: "http://cloud-api.helmcode.com/api/usage/quota"))

        #expect(HelmcodeCookieHeader.header(from: cookies, for: secureURL, now: now) ==
            "api=2; root=1; secure=6")
        #expect(HelmcodeCookieHeader.header(from: cookies, for: insecureURL, now: now) == "api=2; root=1")
    }

    @Test
    func `nan cookies never leak into helmcode requests`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cookies = try [
            self.cookie(name: "session", value: "nan", domain: ".nan.builders", path: "/"),
            self.cookie(name: "session", value: "helm", domain: ".helmcode.com", path: "/"),
        ]
        let nanURL = try #require(URL(string: "https://cloud-api.nan.builders/api/usage/quota"))
        let helmcodeURL = try #require(URL(string: "https://cloud-api.helmcode.com/api/usage/quota"))

        #expect(HelmcodeCookieHeader.header(from: cookies, for: nanURL, now: now) == "session=nan")
        #expect(HelmcodeCookieHeader.header(from: cookies, for: helmcodeURL, now: now) == "session=helm")
    }

    @Test
    func `imported domain scoped cookies match subdomain api hosts`() throws {
        let record = BrowserCookieRecord(
            domain: "nan.builders",
            name: "nan_session",
            path: "/",
            value: "fixture",
            expires: Date(timeIntervalSince1970: 1_900_000_000),
            isSecure: true,
            isHTTPOnly: true,
            scope: .domain)
        let cookies = HelmcodeCookieImporter.makeCookies(from: [record])
        let nanURL = try #require(URL(string: "https://cloud-api.nan.builders/api/usage/quota"))
        let dashboardURL = try #require(URL(string: "https://cloud.nan.builders/dashboard"))

        #expect(cookies.first?.domain == ".nan.builders")
        #expect(HelmcodeCookieHeader.header(from: cookies, for: nanURL) == "nan_session=fixture")
        #expect(HelmcodeCookieHeader.header(from: cookies, for: dashboardURL) == "nan_session=fixture")

        let hostOnlyRecord = BrowserCookieRecord(
            domain: "cloud-api.nan.builders",
            name: "host_session",
            path: "/",
            value: "host",
            expires: Date(timeIntervalSince1970: 1_900_000_000),
            isSecure: true,
            isHTTPOnly: true,
            scope: .hostOnly)
        let hostOnlyCookies = HelmcodeCookieImporter.makeCookies(from: [hostOnlyRecord])
        #expect(HelmcodeCookieHeader.header(from: hostOnlyCookies, for: nanURL) == "host_session=host")
        let otherHost = try #require(URL(string: "https://cloud.nan.builders/dashboard"))
        #expect(HelmcodeCookieHeader.header(from: hostOnlyCookies, for: otherHost) == nil)
    }

    private func cookie(
        name: String,
        value: String,
        domain: String,
        path: String,
        expires: Date? = nil,
        secure: Bool = false) throws -> HTTPCookie
    {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if let expires {
            properties[.expires] = expires
        }
        if secure {
            properties[.secure] = "TRUE"
        }
        return try #require(HTTPCookie(properties: properties))
    }
}
