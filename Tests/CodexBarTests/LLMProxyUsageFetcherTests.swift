import Foundation
import Testing
@testable import CodexBarCore

struct LLMProxyUsageFetcherTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `parses quota stats summary`(engine: ProviderPluginEngineKind) async throws {
        let json = """
        {
          "providers": {
            "openai": {
              "credential_count": 3,
              "active_count": 2,
              "exhausted_count": 1,
              "total_requests": 120,
              "tokens": {
                "input_cached": 1000,
                "input_uncached": 2000,
                "output": 3000
              },
              "approx_cost": 12.5,
              "quota_groups": {
                "default": {
                  "remaining_percent": 42,
                  "reset_time": "2026-05-18T12:00:00Z"
                }
              }
            },
            "anthropic": {
              "credential_count": 1,
              "active_count": 1,
              "exhausted_count": 0,
              "total_requests": 40,
              "tokens": {
                "input_cached": 0,
                "input_uncached": 500,
                "output": 500
              },
              "approx_cost": 3.0,
              "quota_groups": [
                { "remaining_percent": 80 }
              ]
            }
          },
          "summary": {
            "total_requests": 160,
            "total_tokens": 7000,
            "approx_cost": 15.5
          }
        }
        """

        let snapshot = try await Self.fetch(json, engine: engine)
        #expect(snapshot.accountOrganization(for: .llmproxy) == "3/4 active keys")
        #expect(snapshot.extraRateWindows?.first?.window.resetDescription == "120 req · 6,000 tok · $12.50")

        #expect(snapshot.identity?.providerID == .llmproxy)
        #expect(snapshot.primary?.usedPercent == 58)
        #expect(snapshot.secondary?.resetDescription == "160 requests")
        #expect(snapshot.tertiary?.resetDescription == "7,000 tokens")
        #expect(snapshot.providerCost?.used == 15.5)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `quota stats url accepts versioned or root base urls`(engine: ProviderPluginEngineKind) async throws {
        for base in [
            "https://proxy.example.com",
            "https://proxy.example.com/v1",
            "http://192.168.1.10/v1",
            "http://proxy.local/v1",
        ] {
            _ = try await Self.fetch(#"{"providers":{}}"#, engine: engine, base: base)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `parses fractional second quota reset times`(engine: ProviderPluginEngineKind) async throws {
        let json = """
        {
          "providers": {
            "openai": {
              "quota_groups": [
                {
                  "remaining_percent": 42,
                  "reset_time": "2026-05-18T12:00:00.123Z"
                }
              ]
            }
          }
        }
        """

        let parsed = try await Self.fetch(json, engine: engine)
        let components = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 5,
            day: 18,
            hour: 12,
            minute: 0,
            second: 0,
            nanosecond: 123_000_000)
        let expected = try #require(components.date)

        #expect(try abs(#require(parsed.primary?.resetsAt).timeIntervalSince(expected)) < 0.001)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `sums missing summary ignores elapsed resets and limits sorted provider rows`(
        engine: ProviderPluginEngineKind) async throws
    {
        let json = #"""
        {"providers":{
          "delta":{"total_requests":1,"tokens":{"output":2},"approx_cost":0},
          "charlie":{"total_requests":3,"approx_cost":2,"quota_groups":"invalid"},
          "bravo":{"total_requests":3,"quota_groups":[{"remaining_percent":-10,"reset_time":"1970-01-01T00:00:00Z"}]},
          "alpha":{"total_requests":4,"approx_cost":3,"quota_groups":{"a":{"reset_time":"2026-05-01T00:00:00Z"}}}
        }}
        """#
        let usage = try await Self.fetch(json, engine: engine)
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetsAt == ISO8601DateParser.parse("2026-05-01T00:00:00Z"))
        #expect(usage.secondary?.resetDescription == "11 requests")
        #expect(usage.tertiary?.resetDescription == "2 tokens")
        #expect(usage.providerCost?.used == 5)
        #expect(usage.extraRateWindows?.map(\.id) == ["alpha", "bravo", "charlie"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero summary spend is retained and empty providers stay displayable`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(#"{"providers":{},"summary":{"approx_cost":0}}"#, engine: engine)
        #expect(usage.primary == nil)
        #expect(usage.providerCost?.used == 0)
        #expect(usage.secondary?.resetDescription == "0 requests")
        #expect(usage.identity?.accountOrganization == "0/0 active keys")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rejects malformed payloads and classifies HTTP errors without retry`(
        engine: ProviderPluginEngineKind) async throws
    {
        for body in ["not json", "{}", #"{"providers":{"a":{"total_requests":"3"}}}"#] {
            do {
                _ = try await Self.fetch(body, engine: engine)
                Issue.record("Expected parse failure")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
            }
        }
        for (status, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
            (403, .permissionDenied),
            (429, .rateLimited),
            (500, .providerUnavailable),
            (400, .apiFailure),
        ] {
            do {
                _ = try await Self.fetch("error", engine: engine, status: status)
                Issue.record("Expected HTTP failure")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == kind)
                #expect(error.retryAfterSeconds == nil)
            }
        }
    }

    private static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind,
        base: String = "https://proxy.example.com",
        status: Int = 200) async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.path == "/v1/quota-stats")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return (Data(body.utf8), HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        return try await BundledPluginTestSupport.runtime("llmproxy", engine: engine, transport: transport)
            .fetchUsage(
                settings: ["LLM_PROXY_BASE_URL": base],
                secrets: ["LLM_PROXY_API_KEY": "fixture-key"],
                now: Date(timeIntervalSince1970: 1))
    }
}
