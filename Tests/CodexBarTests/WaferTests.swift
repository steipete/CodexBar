import Foundation
import Testing
@testable import CodexBarCore

struct WaferTests {
    @Test
    func `settings reader resolves API key from environment`() {
        let envWithWaferApiKey = [
            "WAFER_API_KEY": "wfr_test_12345",
        ]
        let envWithWaferKey = [
            "WAFER_KEY": "wfr_test_67890",
        ]
        let envWithBoth = [
            "WAFER_API_KEY": "wfr_test_primary",
            "WAFER_KEY": "wfr_test_fallback",
        ]
        let envEmpty = [String: String]()

        #expect(WaferSettingsReader.apiKey(environment: envWithWaferApiKey) == "wfr_test_12345")
        #expect(WaferSettingsReader.apiKey(environment: envWithWaferKey) == "wfr_test_67890")
        #expect(WaferSettingsReader.apiKey(environment: envWithBoth) == "wfr_test_primary")
        #expect(WaferSettingsReader.apiKey(environment: envEmpty) == nil)
    }

    @Test
    func `settings reader cleans quotes from api key`() {
        let envQuotes = [
            "WAFER_API_KEY": "\"wfr_quoted_key\"",
        ]
        let envSingleQuotes = [
            "WAFER_API_KEY": "'wfr_single_quoted_key'",
        ]
        #expect(WaferSettingsReader.apiKey(environment: envQuotes) == "wfr_quoted_key")
        #expect(WaferSettingsReader.apiKey(environment: envSingleQuotes) == "wfr_single_quoted_key")
    }

    @Test
    func `snapshot builds correct UsageSnapshot when active`() {
        let snapshot = WaferUsageSnapshot(isAvailable: true, updatedAt: Date())
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetDescription == "Subscription Active")
        #expect(usage.identity?.loginMethod == "Wafer Pass")
        #expect(usage.identity?.providerID == .wafer)
        #expect(usage.secondary == nil)
    }

    @Test
    func `snapshot builds correct UsageSnapshot when inactive`() {
        let snapshot = WaferUsageSnapshot(isAvailable: false, updatedAt: Date())
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "Inactive / Limit Exceeded")
        #expect(usage.identity?.loginMethod == "Wafer Pass")
    }

    @Test
    func `usage fetcher handles active valid API key successfully`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.absoluteString == "https://pass.wafer.ai/v1/models")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer wfr_active")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data("{\"data\": []}".utf8), response)
        }

        let fetcher = try await WaferUsageFetcher.fetchUsage(apiKey: "wfr_active", session: transport)
        #expect(fetcher.isAvailable == true)
    }

    @Test
    func `usage fetcher handles invalid API key and throws error`() async {
        let transport = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil)!
            return (Data("{\"error\": \"Unauthorized\"}".utf8), response)
        }

        await #expect(throws: WaferUsageError.self) {
            _ = try await WaferUsageFetcher.fetchUsage(apiKey: "wfr_invalid", session: transport)
        }
    }

    @Test
    func `usage fetcher handles malformed JSON response and throws error`() async {
        let transport = ProviderHTTPTransportStub { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data("{\"bad_key\": 123}".utf8), response)
        }

        await #expect(throws: WaferUsageError.self) {
            _ = try await WaferUsageFetcher.fetchUsage(apiKey: "wfr_active", session: transport)
        }
    }
}
