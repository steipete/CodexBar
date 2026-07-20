import CodexBarCore
import Foundation
import Testing

struct GroqConsoleFetcherTests {
    /// A JWT whose payload carries the Groq organization claim. Signature is a
    /// placeholder — only the (unverified) payload segment is read.
    private static func makeJWT(orgID: String) -> String {
        let payload = "{\"https://groq.com/organization\":{\"id\":\"\(orgID)\"}}"
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    @Test
    func `decodes organization id from jwt claim`() {
        let jwt = Self.makeJWT(orgID: "org_abc123")
        #expect(GroqConsoleFetcher.organizationID(fromJWT: jwt) == "org_abc123")
    }

    @Test
    func `falls back to stytch slug when groq claim absent`() {
        let payload = "{\"https://stytch.com/organization\":{\"slug\":\"org_slug9\"}}"
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "h.\(encoded).s"
        #expect(GroqConsoleFetcher.organizationID(fromJWT: jwt) == "org_slug9")
    }

    @Test
    func `returns nil for malformed jwt`() {
        #expect(GroqConsoleFetcher.organizationID(fromJWT: "not-a-jwt") == nil)
        #expect(GroqConsoleFetcher.organizationID(fromJWT: "only.two") == nil)
    }

    @Test
    func `aggregates activity rows into daily buckets`() throws {
        // Two models on the same UTC day plus one on the next day.
        let json = """
        {"object":"list","data":[
          {"organization_name":"Personal","model":"llama-3.1-8b-instant","timestamp":1783900800,
           "num_requests":3,"n_context_tokens_total":100,"n_non_cached_context_tokens_total":80,
           "n_generated_tokens_total":40,"cost":0.01},
          {"organization_name":"Personal","model":"openai/gpt-oss-120b","timestamp":1783901000,
           "num_requests":2,"n_context_tokens_total":50,"n_non_cached_context_tokens_total":50,
           "n_generated_tokens_total":10,"cost":0.02},
          {"organization_name":"Personal","model":"llama-3.1-8b-instant","timestamp":1783987200,
           "num_requests":1,"n_context_tokens_total":10,"n_non_cached_context_tokens_total":10,
           "n_generated_tokens_total":5,"cost":0.005}
        ]}
        """
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))

        let snapshot = try GroqConsoleFetcher._makeSnapshotForTesting(
            activityJSON: Data(json.utf8),
            historyDays: 30,
            updatedAt: Date(timeIntervalSince1970: 1_783_987_200),
            calendar: calendar)

        #expect(snapshot.daily.count == 2)
        #expect(snapshot.organizationName == "Personal")

        // Day one merges the two models.
        let dayOne = snapshot.daily.first
        #expect(dayOne?.requests == 5)
        #expect(dayOne?.inputTokens == 130) // 80 + 50 non-cached
        #expect(dayOne?.cachedInputTokens == 20) // (100-80) + (50-50)
        #expect(dayOne?.outputTokens == 50) // 40 + 10
        #expect(dayOne?.totalTokens == 200) // (100+40) + (50+10)
        #expect((dayOne?.costUSD ?? 0) == 0.03)
        #expect(dayOne?.models.count == 2)

        // Window totals surface via the cost-history projection.
        let projected = snapshot.toCostUsageTokenSnapshot()
        #expect(projected.last30DaysRequests == 6)
        #expect(abs((projected.last30DaysCostUSD ?? 0) - 0.035) < 1e-9)
    }

    @Test
    func `parses session and jwt from cookie header`() {
        let header = "stytch_session=opaque123; stytch_session_jwt=jwt.abc.def; other=x"
        let session = GroqConsoleSession.session(fromCookieHeader: header)
        #expect(session?.sessionToken == "opaque123")
        #expect(session?.directJWT == "jwt.abc.def")
    }

    @Test
    func `usage snapshot exposes provider cost and console usage`() {
        let bucket = GroqConsoleUsageSnapshot.DailyBucket(
            day: "2026-07-13",
            startTime: Date(timeIntervalSince1970: 1_783_900_800),
            endTime: Date(timeIntervalSince1970: 1_783_987_200),
            costUSD: 0.5,
            requests: 10,
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 50,
            totalTokens: 150,
            models: [])
        let snapshot = GroqConsoleUsageSnapshot(
            daily: [bucket],
            updatedAt: Date(timeIntervalSince1970: 1_783_987_200),
            historyDays: 30,
            organizationName: "Personal")
            .toUsageSnapshot()

        #expect(snapshot.identity?.providerID == .groq)
        #expect(snapshot.identity?.loginMethod == "Console")
        #expect(snapshot.providerCost?.used == 0.5)
        #expect(snapshot.groqConsoleUsage?.daily.count == 1)
    }
}
