import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct AixyPluginTests {
    #if canImport(JavaScriptCore)
    static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif

    static func runtime(
        _ name: String,
        engine: ProviderPluginEngineKind,
        transport: any ProviderHTTPTransport) throws -> ProviderPluginRuntime
    {
        let bundle = try #require(CodexBarCoreResources.bundle)
        let url = try #require(bundle.url(forResource: name, withExtension: "js"))
        return try ProviderPluginRuntime(
            source: String(contentsOf: url, encoding: .utf8),
            transport: transport,
            engine: engine)
    }

    static let fixture = #"""
    {
      "object": "key.usage",
      "currency": "USD",
      "as_of": "2026-09-24T12:00:00+00:00",
      "key": {
        "id": "11111111-1111-4111-8111-111111111111",
        "name": "Developer CLI",
        "project_id": "22222222-2222-4222-8222-222222222222",
        "project_name": "Engineering"
      },
      "usage": {
        "window": "7d",
        "requests": 12,
        "input_tokens": 1000,
        "output_tokens": 200,
        "total_tokens": 1200,
        "spend_usd": 1.25,
        "attributed_requests": 10,
        "estimated_requests": 8,
        "provider_reported_requests": 1,
        "reconciled_requests": 1,
        "partial_requests": 2
      },
      "budgets": [
        {
          "id": "33333333-3333-4333-8333-333333333333",
          "object": "cost.personal_budget",
          "scope": "project",
          "target_id": "22222222-2222-4222-8222-222222222222",
          "target_name": "Engineering",
          "interval": "monthly",
          "limit_usd": "100",
          "warning_threshold_percent": 80,
          "enforcement": "hard",
          "allocation": "shared",
          "shared": true,
          "applies_to": [
            {
              "api_key_id": "11111111-1111-4111-8111-111111111111",
              "api_key_name": "Developer CLI",
              "project_id": "22222222-2222-4222-8222-222222222222",
              "project_name": "Engineering",
              "team_id": null,
              "team_name": null
            }
          ],
          "spend_usd": "20",
          "remaining_usd": "80",
          "utilization_percent": 20,
          "state": "healthy",
          "starts_at": "2026-09-01T00:00:00+00:00",
          "resets_at": "2026-10-01T00:00:00+00:00",
          "spend_status": "available",
          "availability": {
            "status": "available",
            "spent_usd": "20",
            "reserved_usd": "10",
            "remaining_usd": "70"
          }
        },
        {
          "id": "44444444-4444-4444-8444-444444444444",
          "object": "cost.personal_budget",
          "scope": "user",
          "target_id": "66666666-6666-4666-8666-666666666666",
          "target_name": "Engineering",
          "interval": "weekly",
          "limit_usd": "100",
          "warning_threshold_percent": 80,
          "enforcement": "monitor",
          "allocation": "shared",
          "shared": false,
          "applies_to": [
            {
              "api_key_id": "11111111-1111-4111-8111-111111111111",
              "api_key_name": "Developer CLI",
              "project_id": "22222222-2222-4222-8222-222222222222",
              "project_name": "Engineering",
              "team_id": null,
              "team_name": null
            }
          ],
          "spend_usd": "40",
          "remaining_usd": "60",
          "utilization_percent": 40,
          "state": "healthy",
          "starts_at": "2026-09-21T00:00:00+00:00",
          "resets_at": "2026-09-28T00:00:00+00:00",
          "spend_status": "available",
          "availability": {
            "status": "not_enforced",
            "spent_usd": null,
            "reserved_usd": null,
            "remaining_usd": null
          }
        },
        {
          "id": "55555555-5555-4555-8555-555555555555",
          "object": "cost.personal_budget",
          "scope": "organization",
          "target_id": null,
          "target_name": "Engineering",
          "interval": "daily",
          "limit_usd": "100",
          "warning_threshold_percent": 80,
          "enforcement": "hard",
          "allocation": "shared",
          "shared": true,
          "applies_to": [
            {
              "api_key_id": "11111111-1111-4111-8111-111111111111",
              "api_key_name": "Developer CLI",
              "project_id": "22222222-2222-4222-8222-222222222222",
              "project_name": "Engineering",
              "team_id": null,
              "team_name": null
            }
          ],
          "spend_usd": null,
          "remaining_usd": null,
          "utilization_percent": null,
          "state": "unknown",
          "starts_at": "2026-09-24T00:00:00+00:00",
          "resets_at": "2026-09-25T00:00:00+00:00",
          "spend_status": "unavailable",
          "availability": {
            "status": "unavailable",
            "spent_usd": null,
            "reserved_usd": null,
            "remaining_usd": null
          }
        }
      ]
    }
    """#

    @Test(arguments: AixyPluginTests.engines)
    func `key usage keeps overlapping budgets and reservations separate`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(Self.fixture, engine: engine)
        #expect(usage.primary?.usedPercent == 30)
        #expect(usage.secondary?.usedPercent == 40)
        #expect(usage.primary?.windowMinutes == 43200)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.primary?.resetDescription?.contains("Shared · Hard") == true)
        #expect(usage.primary?.resetDescription?.contains("$70.00 remaining") == true)
        #expect(usage.extraRateWindows?.count == 1)
        #expect(usage.extraRateWindows?.first?.usageKnown == false)
        #expect(usage.extraRateWindows?.first?.window.resetsAt != nil)
        #expect(usage.providerCost?.used == 1.25)
        #expect(usage.providerCost?.period == "Last 7 days · attributed")
        #expect(usage.identity?.providerID == .aixy)
        #expect(usage.identity?.accountEmail == nil)
        #expect(usage.identity?.accountOrganization == nil)
        #expect(usage.details.first?.rows.first?.value == "Developer CLI")
        #expect(usage.details[1].rows.first?.secondaryValue == "$20.00 spent · $10.00 reserved")
    }

    @Test(arguments: AixyPluginTests.engines)
    func `absent budgets never become an invented quota and absent analytics stays unknown`(
        engine: ProviderPluginEngineKind) async throws
    {
        var body = try Self.body()
        body["budgets"] = []
        var usage = try await Self.fetch(Self.encode(body), engine: engine)
        #expect(usage.primary == nil)
        #expect(usage.providerCost?.used == 1.25)
        body["usage"] = NSNull()
        usage = try await Self.fetch(Self.encode(body), engine: engine)
        #expect(usage.primary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.details.last?.rows.first?.value == "Unavailable")
    }

    @Test(arguments: AixyPluginTests.engines)
    func `zero activity preserves budgets and distinguishes zero from unavailable spend`(
        engine: ProviderPluginEngineKind) async throws
    {
        var body = try Self.body()
        var totals = try #require(body["usage"] as? [String: Any])
        for field in [
            "requests", "input_tokens", "output_tokens", "total_tokens", "spend_usd",
            "attributed_requests", "estimated_requests", "provider_reported_requests",
            "reconciled_requests", "partial_requests",
        ] {
            totals[field] = 0
        }
        for spend in [0, NSNull()] as [Any] {
            totals["spend_usd"] = spend
            body["usage"] = totals
            let usage = try await Self.fetch(Self.encode(body), engine: engine)
            #expect(usage.primary?.usedPercent == 30)
            #expect(usage.secondary?.usedPercent == 40)
            #expect(usage.providerCost?.used == (spend is NSNull ? nil : 0))
            #expect(usage.details.last?.rows[2].value == (spend is NSNull ? "Unavailable" : "$0.00"))
        }
        totals["spend_usd"] = 1
        body["usage"] = totals
        let encoded = try Self.encode(body)
        await Self.expectFailure(.parseFailure) { try await Self.fetch(encoded, engine: engine) }
    }

    @Test(arguments: AixyPluginTests.engines)
    func `all supported base URL forms request only key usage`(engine: ProviderPluginEngineKind) async throws {
        for base in ["https://api.aixy-gateway.com", "https://aixy.example.com/prefix/v1/", "http://localhost:8080"] {
            _ = try await Self.fetch(Self.fixture, engine: engine, base: base)
        }
    }

    @Test(arguments: AixyPluginTests.engines)
    func `invalid auth and service responses are classified without echoing bodies`(
        engine: ProviderPluginEngineKind) async
    {
        for (status, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
            (403, .permissionDenied),
            (404, .apiFailure),
            (429, .rateLimited),
            (503, .providerUnavailable),
        ] {
            await Self.expectFailure(kind) {
                try await Self.fetch("private upstream body", engine: engine, status: status)
            }
        }
    }

    @Test(arguments: AixyPluginTests.engines)
    func `invalid or cross-key responses cannot publish misleading balances`(
        engine: ProviderPluginEngineKind) async throws
    {
        for kind in ["currency", "key", "amount", "duplicate", "date", "coverage", "tokens"] {
            var body = try Self.body()
            var budgets = try #require(body["budgets"] as? [[String: Any]])
            switch kind {
            case "currency": body["currency"] = "EUR"
            case "key":
                body["key"] = ["id": "different-key", "project_id": "different-project"]
            case "amount": budgets[0]["limit_usd"] = "NaN"
            case "duplicate": budgets.append(budgets[0])
            case "date": budgets[0]["resets_at"] = "invalid"
            case "coverage":
                var totals = try #require(body["usage"] as? [String: Any])
                totals["attributed_requests"] = 13
                body["usage"] = totals
            case "tokens":
                var totals = try #require(body["usage"] as? [String: Any])
                totals["total_tokens"] = 1e30
                body["usage"] = totals
            default: break
            }
            body["budgets"] = budgets
            let encoded = try Self.encode(body)
            await Self.expectFailure(.parseFailure) { try await Self.fetch(encoded, engine: engine) }
        }
    }

    static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind,
        status: Int = 200,
        base: String = "https://api.aixy-gateway.com") async throws -> UsageSnapshot
    {
        let runtime = try AixyPluginTests.runtime(
            "aixy",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let root = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let expected = (root.hasSuffix("/v1") ? String(root.dropLast(3)) : root) + "/v1/usage"
                #expect(request.httpMethod == "GET")
                #expect(request.url?.absoluteString == expected)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer gak_fixture")
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
        return try await runtime.fetchUsage(settings: ["AIXY_BASE_URL": base], secrets: ["AIXY_API_KEY": "gak_fixture"])
    }

    static func body() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(self.fixture.utf8)) as? [String: Any])
    }

    static func encode(_ body: [String: Any]) throws -> String {
        try #require(String(
            bytes: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
            encoding: .utf8))
    }

    static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected \(kind)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.localizedDescription.contains("private upstream body"))
        } catch { Issue.record("Unexpected error: \(error)") }
    }
}
