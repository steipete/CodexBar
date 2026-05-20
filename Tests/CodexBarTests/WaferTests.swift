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
        let snapshot = WaferUsageSnapshot(
            limit: 1000,
            count: 123,
            remaining: 877,
            secondsToReset: 3600,
            usedPercent: 12.3,
            windowMinutes: 300,
            updatedAt: Date())
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 12.3)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetDescription == "123/1000 requests")
        #expect(usage.identity?.loginMethod == "Wafer Pass")
        #expect(usage.identity?.providerID == .wafer)
        #expect(usage.secondary == nil)
    }

    @Test
    func `snapshot builds correct UsageSnapshot when inactive`() {
        let snapshot = WaferUsageSnapshot(
            limit: 1000,
            count: 1000,
            remaining: 0,
            secondsToReset: 7200,
            usedPercent: 100.0,
            windowMinutes: 240, // 4-hour window
            updatedAt: Date())
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100.0)
        #expect(usage.primary?.windowMinutes == 240)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(usage.identity?.loginMethod == "Wafer Pass")
    }

    @Test
    func `usage fetcher handles active valid API key successfully`() async throws {
        let quotaJSON = """
        {
            "included_request_limit": 1000,
            "included_request_count": 1,
            "remaining_included_requests": 999,
            "seconds_to_window_end": 16449,
            "current_period_used_percent": 0.1,
            "window_start": "2026-05-20T00:00:00+00:00",
            "window_end": "2026-05-20T05:00:00+00:00"
        }
        """

        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.absoluteString == "https://pass.wafer.ai/v1/inference/quota")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer wfr_active")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(quotaJSON.utf8), response)
        }

        let fetcher = try await WaferUsageFetcher.fetchUsage(apiKey: "wfr_active", session: transport)
        #expect(fetcher.limit == 1000)
        #expect(fetcher.count == 1)
        #expect(fetcher.remaining == 999)
        #expect(fetcher.secondsToReset == 16449)
        #expect(fetcher.usedPercent == 0.1)
        #expect(fetcher.windowMinutes == 300) // 5 hours dynamically resolved
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
