import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

@Suite(ClaudeOAuthDefaultsFixtures())
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

    @Test(arguments: [400, 403])
    func `unsupported inventory query retries once with legacy identity and retains ordinary usage`(
        status: Int) async throws
    {
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
                    statusCode: inventory ? status : 200,
                    httpVersion: nil,
                    headerFields: nil)))
        }
        let usage = try await ClaudeOAuthUsageFetcher.fetchUsage(
            accessToken: "synthetic-unsupported-query", detectClaudeVersion: false, transport: transport)
        let requests = await transport.requests()
        #expect(requests.map { $0.url?.query } == ["cedar_ember=1", nil])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-unsupported-query"
                && $0.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20"
        })
        #expect(usage.fiveHour?.utilization == 12)
        #expect(usage.extraUsage?.usedCredits == 300)
    }

    @Test(arguments: [401, 403, 429, 500])
    func `authentication scope rate limit and server errors do not retry`(status: Int) async throws {
        let body = #"{"error":"Missing required scope user:profile"}"#
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Retry-After": "300"])))
        }
        let error = await #expect(throws: ClaudeOAuthFetchError.self) {
            try await ClaudeOAuthUsageFetcher.fetchUsage(
                accessToken: "synthetic-terminal-\(UUID().uuidString)",
                detectClaudeVersion: false,
                transport: transport)
        }
        switch (status, error) {
        case (401, .unauthorized), (429, .rateLimited): break
        case let (_, .serverError(code, receivedBody)):
            #expect(code == status)
            #expect(receivedBody == body)
        default: Issue.record("Lost OAuth error classification")
        }
        #expect(await transport.requests().count == 1)
    }

    @Test(arguments: [400, 403])
    func `ordinary usage rejection ends the fallback after two requests`(status: Int) async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return try (Data("{}".utf8), #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        }
        await #expect(throws: ClaudeOAuthFetchError.self) {
            try await ClaudeOAuthUsageFetcher.fetchUsage(
                accessToken: "synthetic-rejected-\(status)", detectClaudeVersion: false, transport: transport)
        }
        let requests = await transport.requests()
        #expect(requests.map { $0.url?.query } == ["cedar_ember=1", nil])
        #expect(requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalCacheData })
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
        #expect(!json.contains("private grant"))
        #expect(!json.contains("cedar_ember"))
        #expect(!json.contains("claude-cli/"))
        #expect(usage.rawText == nil)
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)
        #expect(restored.claudeResetCredits == nil)
        #expect(restored.detailRow(label: "Limit Reset Credits") == nil)
    }

    @Test
    func `spend only OAuth keeps inventory and its primary window kind`() throws {
        let payload = Self.payload(block: Self.eligibleBlock)
            .replacingOccurrences(of: #""five_hour":{"utilization":12},"#, with: "")
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(payload.utf8))
        #expect(usage.primary == nil)
        #expect(usage.providerCost?.spendLimitWindow?.usedPercent == 30)
        #expect(usage.secondary == nil)
        #expect(usage.opus == nil)
        #expect(usage.providerCost?.used == 3)
        #expect(usage.resetCredits?.expirations.count == 2)
        let snapshot = ClaudeOAuthFetchStrategy._snapshotForTesting(from: usage)
        #expect(snapshot.primary == nil)
        #expect(snapshot.detailRow(label: "Limit Reset Credits")?.value == "2 available")
    }

    @Test(arguments: [
        "null",
        "{}",
        "{\"eligible\":false,\"grants\":[]}",
        "{\"eligible\":true,\"grants\":\"invalid\"}",
    ])
    func `absent ineligible or malformed inventory preserves quota and spend`(block: String) throws {
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(Self.payload(block: block).utf8))
        #expect(usage.primary?.usedPercent == 12)
        #expect(usage.providerCost != nil)
        #expect(usage.resetCredits == nil)
    }

    @Test(arguments: [200, 201])
    func `grant record cap counts malformed records without losing ordinary OAuth usage`(count: Int) throws {
        let grants = ([#"{"resets_left":1,"paused":false}"#]
            + Array(repeating: "{}", count: count - 1))
            .joined(separator: ",")
        let usage = try ClaudeUsageFetcher._mapOAuthUsageForTesting(Data(Self.payload(
            block: "{\"eligible\":true,\"grants\":[\(grants)]}").utf8))
        #expect(usage.primary?.usedPercent == 12)
        #expect(usage.resetCredits?.expirations.count == (count <= 200 ? 1 : nil))
    }

    @Test
    func `inventory session has no URL cache and retains redirect protection`() {
        let session = ProviderHTTPClient.redirectGuardedSession(
            configuration: ClaudeOAuthUsageFetcher.usageSessionConfiguration())
        defer { session.invalidateAndCancel() }
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.timeoutIntervalForResource == 90)
        #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(session.delegate is ProviderHTTPRedirectGuardDelegate)
    }

    @Test(arguments: [401, 429, 500])
    func `fallback preserves terminal errors and token scoped rate limit state`(status: Int) async throws {
        let token = "synthetic-fallback-\(status)"
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return try (Data("{}".utf8), #require(HTTPURLResponse(
                url: url,
                statusCode: url.query == nil ? status : 400,
                httpVersion: nil,
                headerFields: ["Retry-After": "300"])))
        }
        let error = await #expect(throws: ClaudeOAuthFetchError.self) {
            try await ClaudeOAuthUsageFetcher.fetchUsage(
                accessToken: token, detectClaudeVersion: false, transport: transport)
        }
        switch (status, error) {
        case (401, .unauthorized), (429, .rateLimited): break
        case let (500, .serverError(code, _)): #expect(code == 500)
        default: Issue.record("Lost fallback error classification")
        }
        #expect(await transport.requests().count == 2)
        if status == 429 {
            let key = ClaudeOAuthUsageRateLimitGate.storageKeyForTesting(accessToken: token)
            let stored = ClaudeOAuthDefaultsFixtures.defaults.dictionaryRepresentation()
            #expect(stored[key] is Double)
            #expect(!key.contains(token))
            #expect(!key.contains("cedar_ember"))
            await #expect(throws: ClaudeOAuthFetchError.self) {
                try await ClaudeOAuthUsageFetcher.fetchUsage(
                    accessToken: token, detectClaudeVersion: false, transport: transport)
            }
            #expect(await transport.requests().count == 2)
        }
    }

    @Test
    func `cancellation after inventory rejection prevents the fallback request`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            withUnsafeCurrentTask { $0?.cancel() }
            let url = try #require(request.url)
            return try (Data("{}".utf8), #require(HTTPURLResponse(
                url: url, statusCode: 400, httpVersion: nil, headerFields: nil)))
        }
        let task = Task {
            try await ClaudeOAuthUsageFetcher.fetchUsage(
                accessToken: "synthetic-cancelled-inventory", detectClaudeVersion: false, transport: transport)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests().count == 1)
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
