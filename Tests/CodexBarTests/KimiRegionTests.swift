import Foundation
import Testing
@testable import CodexBarCore

struct KimiRegionTests {
    @Test(arguments: KimiRegion.allCases)
    func `region resolves API console and cookie domains`(region: KimiRegion) throws {
        let domain = region == .china ? "kimi.com" : "kimi.ai"
        #expect(try KimiSettingsReader.codeAPIBaseURL(region: region, environment: [:])
            .absoluteString == "https://api.\(domain)")
        #expect(region.consoleURL.absoluteString == "https://www.\(domain)/code/console")
        #expect(region.cookieDomains == ["www.\(domain)", domain])
        #expect(try KimiSettingsReader.codeAPIBaseURL(region: region, environment: [
            "KIMI_CODE_BASE_URL": "https://proxy.example.com/coding/v1",
        ]).absoluteString == "https://proxy.example.com/coding/v1")
    }

    @Test(arguments: KimiRegion.allCases, [false, true])
    func `usage and membership requests stay on selected region`(region: KimiRegion, codeAPI: Bool) async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "device_id": "fixture-device", "ssid": "fixture-session", "sub": "fixture-traffic",
        ]).base64EncodedString()
        let token = "header.\(payload).signature"
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let body: String
            if url.path == "/coding/v1/usages" {
                #expect(url.host == "api.\(region.domain)")
                body = #"{"usage":{"limit":"100","used":"25","remaining":"75"}}"#
            } else {
                #expect(url.host == "www.\(region.domain)")
                #expect(request.value(forHTTPHeaderField: "Origin") == region.webBaseURL.absoluteString)
                #expect(request.value(forHTTPHeaderField: "Referer") == region.consoleURL.absoluteString)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
                #expect(request.value(forHTTPHeaderField: "x-msh-device-id") == "fixture-device")
                #expect(request.value(forHTTPHeaderField: "x-msh-session-id") == "fixture-session")
                #expect(request.value(forHTTPHeaderField: "x-traffic-id") == "fixture-traffic")
                body = url.lastPathComponent == "GetUsages"
                    ? #"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","used":"25","remaining":"75"}}]}"#
                    : "{}"
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        if codeAPI {
            _ = try await KimiUsageFetcher.fetchCodeAPIUsage(
                apiKey: "synthetic-key", region: region, webAuthToken: token, transport: transport)
        } else {
            _ = try await KimiUsageFetcher.fetchUsage(authToken: token, region: region, transport: transport)
        }
        #expect(await transport.requests().count == 3)
    }

    @Test(arguments: [
        "kimi-auth=synthetic.token.value; other=value",
        "KIMI-AUTH: synthetic.token.value",
        "Cookie: kimi-auth=synthetic.token.value; other=value",
        "-H 'Cookie: other=value; kimi-auth=synthetic.token.value'",
        "-H \"Cookie: kimi-auth=synthetic.token.value\"",
    ])
    func `cookie token extraction handles header and curl forms in one pass`(raw: String) {
        #expect(KimiCookieHeader.override(from: raw)?.token == "synthetic.token.value")
    }
}
