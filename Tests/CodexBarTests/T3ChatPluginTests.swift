import Foundation
import Testing
@testable import CodexBarCore

struct T3ChatPluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `request preserves web timeout and captured headers`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "t3chat",
            engine: engine,
            transport:
            ProviderHTTPTransportHandler { request in
                #expect(request.timeoutInterval == 60)
                #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture")
                #expect(request.value(forHTTPHeaderField: "X-Deployment-Id") == "fixture-deploy")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://t3.chat")
                #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
                return try CookiePluginFixtures.response(request, body: #"{"usageFourHourPercentage":25}"#)
            })
        let usage = try await runtime.fetchUsage(
            settings: ["TIMEOUT_SECONDS": "60"],
            secrets: ["CAPTURED_HEADERS": #"{"X-Deployment-Id":"fixture-deploy"}"#],
            cookieSource: .manual,
            cookieResolver: { _, _ in "session=fixture" })
        #expect(usage.primary?.usedPercent == 25)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid primary date falls back and whitespace labels stay clean`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "t3chat",
            engine: engine,
            transport:
            ProviderHTTPTransportHandler { request in
                try CookiePluginFixtures.response(
                    request,
                    body:
                    #"{"usageFourHourPercentage":25,"usageFourHourNextResetAt":-1,"# +
                        #""usageWindowNextResetAt":1800000000,"usageBand":"  ","subTier":" pro "}"#)
            })
        let usage = try await runtime.fetchUsage(cookieResolver: { _, _ in "session=fixture" })
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(usage.primary?.resetDescription == "Base")
        #expect(usage.identity?.loginMethod == "Pro")
    }

    @Test(arguments: BundledPluginTestSupport.engines, [401, 403, 429, 500])
    func `HTTP errors retain classified diagnostics`(engine: ProviderPluginEngineKind, status: Int) async throws {
        let rejected = LockIsolated(false)
        let runtime = try BundledPluginTestSupport.runtime(
            "t3chat",
            engine: engine,
            transport:
            ProviderHTTPTransportHandler { request in
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["x-vercel-mitigated": "challenge"]))
                return (Data("not JSON".utf8), response)
            })
        await CookiePluginFixtures
            .expectFailure(status == 401 || status == 403 ? .authenticationExpired : .apiFailure) {
                try await runtime.fetchUsage(
                    cookieInvalidator: { domain in
                        #expect(domain == "t3.chat")
                        rejected.setValue(true)
                    }, cookieResolver: { _, _ in "session=fixture" })
            }
        #expect(rejected.value == (status == 401 || status == 403))
    }
}
