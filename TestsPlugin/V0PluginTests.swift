import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct V0PluginTests {
    @Test
    func `v0 API fixture maps billing and rate limit windows`() async throws {
        let billing = #"{"billingType":"token","data":{"balance":{"remaining":750,"total":1000},"billingCycle":{"end":1800003600}}}"#
        let rateLimits = #"{"remaining":80,"reset":1800001800000,"limit":100}"#
        let transport = ProviderHTTPTransportHandler { request in
            let body = request.url?.path == "/v1/user/billing" ? billing : rateLimits
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(request.url?.query == "scope=project-demo")
            return (Data(body.utf8), response)
        }
        let runtime = try ProviderPluginRuntime(bundledPlugin: "v0", transport: transport)
        let snapshot = try await runtime.fetchUsage(
            settings: ["V0_SCOPE": "project-demo"],
            secrets: ["V0_API_KEY": "fixture-key"],
            now: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(snapshot.secondary?.usedPercent == 20)
        #expect(snapshot.secondary?.resetsAt == Date(timeIntervalSince1970: 1_800_001_800))
        #expect(snapshot.identity?.loginMethod == "API key")
        #expect(snapshot.dataConfidence == UsageDataConfidence.exact)
        let details = try #require(snapshot.details.first)
        #expect(details.title == "v0 API")
        #expect(details.rows.contains { $0.label == "Billing type" && $0.value == "token" })
        #expect(details.rows.contains { $0.label == "Scope" && $0.value == "project-demo" })
    }

    @Test
    func `v0 API fixture omits scope query when scope is blank`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.query == nil)
            let body = request.url?.path == "/v1/user/billing"
                ? #"{"billingType":"subscription","data":{"remaining":0,"reset":0,"limit":0}}"#
                : #"{"limit":100}"#
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
        let runtime = try ProviderPluginRuntime(bundledPlugin: "v0", transport: transport)
        let snapshot = try await runtime.fetchUsage(
            settings: ["V0_SCOPE": "   "],
            secrets: ["V0_API_KEY": "fixture-key"])

        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.secondary?.resetsAt == nil)
    }
}
