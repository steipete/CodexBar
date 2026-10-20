import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct FutureAGIPluginTests {
    /// Shape from the production OpenAPI UsageOverviewResponse; values are synthetic.
    static let fixture = #"""
    {"status":true,"result":{"plan_display_name":"Free","billing_period_start":"2026-10-01",
    "billing_period_end":"2026-11-01","total_estimated_cost":1.25,"dimensions":[
    {"key":"ai_credits","display_name":"AI credits","display_unit":"credits","current_usage":500,"free_allowance":2000},
    {"key":"gateway_requests","display_name":"Gateway requests","display_unit":"requests",
    "current_usage":150000,"free_allowance":100000},
    {"key":"storage","display_name":"Storage","display_unit":"GB","current_usage":0.5,"free_allowance":1}]}}
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `documented usage preserves allowances overages and billing dates`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(Self.fixture, engine: engine)
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.secondary?.usedPercent == 100)
        #expect(usage.primary?.windowMinutes == 44640)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_793_491_200))
        #expect(usage.details[0].rows.map(\.value) == [
            "500 / 2,000 credits", "150,000 / 100,000 requests", "0.5 / 1 GB",
        ])
        #expect(usage.details[1].rows[0].value == "$1.25")
        #expect(usage.identity?.loginMethod == "Free")
        #expect(usage.providerCost == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero allowances omit bars while retaining measured usage`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(
            Self.fixture.replacingOccurrences(of: "\"free_allowance\":2000", with: "\"free_allowance\":0"),
            engine: engine)
        #expect(usage.primary == nil)
        #expect(usage.details[0].rows[0].value == "500 / 0 credits")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed usage never becomes zero usage`(engine: ProviderPluginEngineKind) async throws {
        for body in [
            #"{"status":false,"result":"private-response"}"#,
            Self.fixture.replacingOccurrences(of: "\"current_usage\":500", with: "\"current_usage\":\"500\""),
            Self.fixture.replacingOccurrences(of: "2026-11-01", with: "invalid-date"),
        ] {
            do {
                _ = try await Self.fetch(body, engine: engine)
                Issue.record("Expected parse failure")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
                #expect(!error.message.contains("private-response"))
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP failures stay classified without echoing response bodies`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            do {
                _ = try await Self.fetch("private-response", engine: engine, code: code)
                Issue.record("Expected classified failure")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == kind)
                #expect(!error.message.contains("private-response"))
            }
        }
    }

    @Test
    func `incomplete credential pairs fail before network access`() async throws {
        for environment in [[:], ["FI_API_KEY": "fixture-key"], ["FI_SECRET_KEY": "fixture-secret"]] {
            let context = ProviderCutoverTestSupport.context(environment: environment)
            let strategies = await FutureAGIProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
            let strategy = try #require(strategies.first)
            do {
                _ = try await strategy.fetch(context)
                Issue.record("Expected missing credential")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .missingCredential)
            }
        }
    }

    private static func fetch(
        _ body: String, engine: ProviderPluginEngineKind, code: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "futureagi",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.futureagi.com/usage/v2/usage-overview/")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "fixture-key")
                #expect(request.value(forHTTPHeaderField: "X-Secret-Key") == "fixture-secret")
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["FI_API_KEY": "fixture-key", "FI_SECRET_KEY": "fixture-secret"])
    }
}
