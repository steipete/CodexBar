import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct GeminiMenuBarWindowTests {
    @Test(arguments: [0.6, 0.0])
    func `Flash Lite-only quota API resolves every Gemini metric`(remainingFraction: Double) async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "test-access-token",
            refreshToken: nil,
            expiry: .distantFuture,
            idToken: nil)
        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            let url = try #require(request.url)
            let body: Data
            switch url.path {
            case "/v1internal:loadCodeAssist":
                body = GeminiAPITestHelpers.loadCodeAssistResponse(
                    tierId: "standard-tier", projectId: "test-project")
            case "/v1internal:retrieveUserQuota":
                body = GeminiAPITestHelpers.jsonData(["buckets": [[
                    "modelId": "gemini-2.5-flash-lite",
                    "remainingFraction": remainingFraction,
                    "resetTime": "2030-01-01T00:00:00Z",
                ]]])
            default:
                throw URLError(.unsupportedURL)
            }
            return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: body)
        }
        let probe = GeminiStatusProbe(homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch().toUsageSnapshot()
        let flashLite = try #require(snapshot.tertiary)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(flashLite.usedPercent == (1 - remainingFraction) * 100)

        for preference in [MenuBarMetricPreference.automatic, .primary, .secondary, .average] {
            let window = MenuBarMetricWindowResolver.rateWindow(
                preference: preference, provider: .gemini, snapshot: snapshot, supportsAverage: true)
            #expect(window == flashLite, "Failed preference: \(preference)")
        }
    }

    @Test
    func `gemini metrics fall back to Flash Lite when Pro and Flash are unavailable`() throws {
        let snapshot = try GeminiStatusProbe.parse(text: """
        gemini-2.5-flash-lite                       12       60.0% (Resets in 6h)
        """).toUsageSnapshot()
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)

        for preference in [MenuBarMetricPreference.automatic, .primary, .secondary, .average] {
            let window = MenuBarMetricWindowResolver.rateWindow(
                preference: preference,
                provider: .gemini,
                snapshot: snapshot,
                supportsAverage: true)

            #expect(window?.usedPercent == 40, "Failed preference: \(preference)")
        }
    }

    @Test
    func `gemini metrics keep Pro over Flash Lite when Flash is unavailable`() throws {
        let snapshot = try GeminiStatusProbe.parse(text: """
        gemini-2.5-pro                               3       70.0% (Resets in 24h)
        gemini-2.5-flash-lite                       12       60.0% (Resets in 6h)
        """).toUsageSnapshot()

        for preference in [MenuBarMetricPreference.automatic, .primary, .secondary, .average] {
            let window = MenuBarMetricWindowResolver.rateWindow(
                preference: preference,
                provider: .gemini,
                snapshot: snapshot,
                supportsAverage: true)

            #expect(window?.usedPercent == 30, "Failed preference: \(preference)")
        }
    }

    @Test
    func `gemini automatic still surfaces an exhausted model tier`() throws {
        let snapshot = try GeminiStatusProbe.parse(text: """
        gemini-2.5-pro                               3       70.0% (Resets in 24h)
        gemini-2.5-flash-lite                       12        0.0% (Resets in 6h)
        """).toUsageSnapshot()

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .gemini,
            snapshot: snapshot,
            supportsAverage: true)

        #expect(window == snapshot.tertiary)
        #expect(window?.usedPercent == 100)
    }
}
