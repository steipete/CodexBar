import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ClaudeOAuthResetCreditsTests {
    @Test
    func `OAuth requests reset inventory without suppressing spend or changing authentication`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path == "/api/oauth/usage")
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [
                URLQueryItem(name: "cedar_ember", value: "1"),
            ])
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-reset-token")
            #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.0 (external, cli)")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return try (Data(Self.payload(block: Self.eligibleBlock).utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let usage = try await ClaudeOAuthUsageFetcher.fetchUsage(
            accessToken: "synthetic-reset-token", detectClaudeVersion: false, transport: transport)
        #expect(usage.extraUsage?.usedCredits == 300)
        #expect(usage.resetStatus?.snapshot(updatedAt: Date())?.expirations.count == 2)
    }

    @Test
    func `unsupported inventory query retries once with legacy identity and retains ordinary usage`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let inventory = url.query != nil
            if !inventory {
                #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.0")
            }
            return try (
                Data(inventory ? "{}".utf8 : Self.payload(block: "null").utf8),
                #require(HTTPURLResponse(
                    url: url,
                    statusCode: inventory ? 403 : 200,
                    httpVersion: nil,
                    headerFields: nil)))
        }
        let usage = try await ClaudeOAuthUsageFetcher.fetchUsage(
            accessToken: "synthetic-unsupported-query", detectClaudeVersion: false, transport: transport)
        #expect(await transport.requests().count == 2)
        #expect(usage.fiveHour?.utilization == 12)
        #expect(usage.extraUsage?.usedCredits == 300)
        #expect(usage.resetStatus == nil)
    }

    @Test
    func `OAuth inventory reaches CLI details without redemption handles or persisted credits`() throws {
        let data = Data(Self.payload(block: Self.eligibleBlock).utf8)
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(data)
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        #expect(snapshot.primary?.usedPercent == 12)
        #expect(snapshot.providerCost != nil)
        #expect(snapshot.detailRow(label: "Limit Reset Credits")?.value == "2 available")
        let encoded = try JSONEncoder().encode(snapshot)
        let json = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(!json.contains("redemption-handle"))
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)
        #expect(restored.claudeResetCredits == nil)
        #expect(restored.detailRow(label: "Limit Reset Credits") == nil)
    }

    @Test(arguments: [
        "null",
        "{}",
        "{\"eligible\":false,\"grants\":[]}",
        "{\"eligible\":true,\"grants\":\"invalid\"}",
    ])
    func `absent ineligible or malformed inventory preserves quota and spend`(block: String) throws {
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(Self.payload(block: block).utf8))
        #expect(usage.primary.usedPercent == 12)
        #expect(usage.providerCost != nil)
        #expect(usage.resetCredits == nil)
    }

    @Test
    func `oversized grant arrays fail soft without losing ordinary OAuth usage`() throws {
        let grants = Array(repeating: "{}", count: ClaudeLimitResetStatusResponse.maximumGrantRecords + 1)
            .joined(separator: ",")
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(Self.payload(
            block: "{\"eligible\":true,\"grants\":[\(grants)]}").utf8))
        #expect(usage.primary.usedPercent == 12)
        #expect(usage.resetCredits == nil)
    }

    private static let eligibleBlock = """
    {"eligible":true,"grants":[
      {"id":"redemption-handle","label":"private grant","resets_left":2,"resets_total":2,
       "starts_at":"2020-01-01T00:00:00Z","ends_at":"2099-01-01T00:00:00Z",
       "paused":false,"usable_now":false},
      {"resets_left":1,"paused":true},
      {"resets_left":1,"paused":false,"ends_at":"2020-01-01T00:00:00Z"},
      {"resets_left":1,"paused":false,"starts_at":"2099-01-01T00:00:00Z"}
    ]}
    """

    private static func payload(block: String) -> String {
        """
        {"five_hour":{"utilization":12},
         "extra_usage":{"is_enabled":true,"monthly_limit":1000,"used_credits":300},
         "cedar_ember":\(block)}
        """
    }
}
