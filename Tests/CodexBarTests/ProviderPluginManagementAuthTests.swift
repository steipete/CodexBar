import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginManagementAuthTests {
    @Test
    func `origin allowlist and HTTP response shape are engine independent`() throws {
        let manifest = try Self.manifest(provider: "openrouter")
        let url = try #require(URL(string: "https://openrouter.ai/api/v1/activity"))
        #expect(try manifest.allowedOrigin(for: url, settings: [:]))
        #expect(try !manifest.allowedOrigin(for: #require(URL(string: "https://other.test")), settings: [:]))
        let response = try ProviderHTTPResponse(
            data: Data(#"{"value":42}"#.utf8),
            response: #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["X-Fixture": "ok"])))
        let json = try ProviderPluginHTTPResponse.payload(response, wantsJSON: true)
        #expect(json["status"] as? Int == 200)
        #expect((json["headers"] as? [String: String])?["x-fixture"] == "ok")
        #expect((json["json"] as? [String: Int])?["value"] == 42)
        let text = try ProviderPluginHTTPResponse.payload(response, wantsJSON: false)
        #expect(text["bodyText"] as? String == #"{"value":42}"#)
    }

    @Test
    func `management auth is pinned to the declared secret and official read endpoint`() throws {
        let manifest = try Self.manifest(provider: "openrouter")
        let url = try #require(URL(string: "https://openrouter.ai/api/v1/activity?date=2026-09-12"))
        #expect(try manifest.openRouterManagementAuthSecret(method: "GET", url: url) ==
            "OPENROUTER_MANAGEMENT_API_KEY")
        #expect(throws: ProviderPluginError.self) {
            try Self.manifest(provider: "synthetic").openRouterManagementAuthSecret(method: "GET", url: url)
        }
        #expect(throws: ProviderPluginError.self) {
            try Self.manifest(provider: "openrouter", kind: "plain")
                .openRouterManagementAuthSecret(method: "GET", url: url)
        }
        #expect(throws: ProviderPluginError.self) {
            try manifest.openRouterManagementAuthSecret(method: "POST", url: url)
        }
    }

    @Test(arguments: [
        "http://openrouter.ai/api/v1/activity",
        "https://other.test/api/v1/activity",
        "https://openrouter.ai:443/api/v1/activity",
        "https://user@openrouter.ai/api/v1/activity",
        "https://openrouter.ai/api/v1/keys",
        "https://openrouter.ai/api/v1/activity#fragment",
    ])
    func `management auth rejects endpoint variations`(rawURL: String) throws {
        let manifest = try Self.manifest(provider: "openrouter")
        let url = try #require(URL(string: rawURL))
        #expect(throws: ProviderPluginError.self) {
            try manifest.openRouterManagementAuthSecret(method: "GET", url: url)
        }
    }

    private static func manifest(provider: String, kind: String = "secure") throws -> ProviderPluginManifest {
        try ProviderPluginManifest(definition: JSONProviderPluginValue([
            "id": provider,
            "name": "Fixture",
            "endpoints": ["https://openrouter.ai"],
            "settings": [["key": "OPENROUTER_MANAGEMENT_API_KEY", "title": "Management", "type": kind]],
        ]))
    }
}
