import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CodexOAuthRequestTests {
    @Test
    func `usage requests do not reuse refreshed quota response across accounts`() async throws {
        let transport = CodexOAuthAccountCachingTransport()

        let refreshed = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: "token-a",
            accountId: "account-a",
            env: ["CODEX_HOME": "/tmp/codexbar-oauth-request-test"],
            session: transport)
        let depleted = try await CodexOAuthUsageFetcher.fetchUsage(
            accessToken: "token-b",
            accountId: "account-b",
            env: ["CODEX_HOME": "/tmp/codexbar-oauth-request-test"],
            session: transport)

        #expect(refreshed.rateLimit?.primaryWindow?.usedPercent == 7)
        #expect(refreshed.rateLimit?.secondaryWindow?.usedPercent == 9)
        #expect(depleted.rateLimit?.primaryWindow?.usedPercent == 100)
        #expect(depleted.rateLimit?.secondaryWindow?.usedPercent == 63)
        #expect(depleted.additionalRateLimits?.first?.rateLimit?.primaryWindow?.usedPercent == 4)

        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData })
        #expect(requests.map { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") } == ["account-a", "account-b"])
    }
}

private actor CodexOAuthAccountCachingTransport: ProviderHTTPTransport {
    private var recordedRequests: [URLRequest] = []
    private var cachedResponses: [URL: (Data, URLResponse)] = [:]

    func requests() -> [URLRequest] {
        self.recordedRequests
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.recordedRequests.append(request)
        guard let url = request.url else { throw URLError(.badURL) }
        if request.cachePolicy != .reloadIgnoringLocalCacheData,
           let cached = self.cachedResponses[url]
        {
            return cached
        }

        let payload = switch request.value(forHTTPHeaderField: "ChatGPT-Account-Id") {
        case "account-a":
            Self.payload(primary: 7, secondary: 9, spark: 2)
        case "account-b":
            Self.payload(primary: 100, secondary: 63, spark: 4)
        default:
            throw URLError(.userAuthenticationRequired)
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Cache-Control": "public, max-age=300"])
        else {
            throw URLError(.badServerResponse)
        }
        let result: (Data, URLResponse) = (Data(payload.utf8), response)
        if request.cachePolicy != .reloadIgnoringLocalCacheData {
            self.cachedResponses[url] = result
        }
        return result
    }

    private static func payload(primary: Int, secondary: Int, spark: Int) -> String {
        """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": \(primary), "reset_at": 1766948068, "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": \(secondary), "reset_at": 1767407914, "limit_window_seconds": 604800
            }
          },
          "additional_rate_limits": [{
            "limit_name": "GPT-5.3-Codex-Spark",
            "rate_limit": {
              "primary_window": {
                "used_percent": \(spark), "reset_at": 1766948068, "limit_window_seconds": 18000
              }
            }
          }]
        }
        """
    }
}
