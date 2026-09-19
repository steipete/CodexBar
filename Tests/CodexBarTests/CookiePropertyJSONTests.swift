import Foundation
import Testing
@testable import CodexBarCore

struct CookiePropertyJSONTests {
    @Test
    func `legacy cookie markers survive JSON serialization`() throws {
        let expiration = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 3600)
        let cookie = try #require(HTTPCookie(properties: [
            .name: "synthetic-session",
            .value: "fixture-value",
            .domain: "example.test",
            .path: "/usage",
            .expires: expiration,
            .secure: "TRUE",
        ]))
        let encoded = CookiePropertyJSON.encode([cookie])
        let bytes = try JSONSerialization.data(withJSONObject: encoded)
        let legacy = try #require(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        let decoded = try #require(CookiePropertyJSON.decode(legacy).first)
        #expect(decoded.name == cookie.name)
        #expect(decoded.value == cookie.value)
        #expect(decoded.domain == cookie.domain)
        #expect(decoded.path == cookie.path)
        #expect(decoded.isSecure)
        #expect(decoded.expiresDate == cookie.expiresDate)
        #expect(encoded.first?[HTTPCookiePropertyKey.expires.rawValue + "_isDate"] as? Bool == true)
    }

    @Test
    func `legacy URL markers are restored and invalid rows are skipped`() {
        let expiration = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 3600)
        let values: [[String: Any]] = [
            [:],
            [
                "Name": "synthetic-session", "Value": "fixture-value", "Path": "/", "Domain": "example.test",
                "OriginURL": "https://example.test", "OriginURL_isURL": true,
                "Expires": expiration.timeIntervalSince1970, "Expires_isDate": true,
            ],
        ]
        let cookies = CookiePropertyJSON.decode(values)
        #expect(cookies.count == 1)
        #expect(cookies.first?.expiresDate == expiration)
        #expect(CookiePropertyJSON.decode([]).isEmpty)
        #expect(CookiePropertyJSON.encode([]).isEmpty)
    }
}
