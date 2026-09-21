import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct NousPluginTests {
    static let account = #"""
    {
      "user": {"email": "dev@example.com"},
      "organisation": {"name": "Example account"},
      "subscription": {
        "plan": "Ultra", "monthly_credits": 220, "credits_remaining": 55,
        "rollover_credits": 0, "current_period_end": "2026-10-12T04:29:00.000Z"
      },
      "purchased_credits_remaining": 19.25,
      "paid_service_access": {"has_active_subscription": true, "total_usable_credits": 74.25}
    }
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `subscription and purchased credits remain separate`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(Self.account, engine: engine)
        #expect(snapshot.primary?.usedPercent == 75)
        #expect(snapshot.primary?.windowMinutes == nil)
        #expect(snapshot.primary?.resetsAt == NousSettingsReader.parseISODate("2026-10-12T04:29:00.000Z"))
        #expect(snapshot.subscriptionRenewsAt == snapshot.primary?.resetsAt)
        #expect(snapshot.identity?.providerID == .nous)
        #expect(snapshot.identity?.accountEmail == "dev@example.com")
        #expect(snapshot.identity?.accountOrganization == "Example account")
        #expect(snapshot.identity?.loginMethod == "Ultra")
        #expect(snapshot.details.map(\.title) == ["Subscription", "Credits"])
        #expect(snapshot.details[0].rows[0].value == "$55.00 of $220.00 left")
        #expect(snapshot.details[1].rows.map(\.value) == ["$19.25", "$74.25"])
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `decimal amounts and exhausted balances are preserved`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"""
        {"subscription":{"monthly_credits":"22","credits_remaining":"0","rollover_credits":"1.5"},
         "purchased_credits_remaining":"3.25"}
        """#, engine: engine)
        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.details[0].rows[1].value == "$1.50")
        #expect(snapshot.details[1].rows[0].value == "$3.25")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `free and partial accounts do not invent quota or money`(engine: ProviderPluginEngineKind) async throws {
        let free = try await Self.fetch(#"{"subscription":null,"purchased_credits_remaining":0}"#, engine: engine)
        #expect(free.primary == nil)
        #expect(free.details.flatMap(\.rows).map(\.value) == ["$0.00"])
        let partial = try await Self.fetch(
            #"{"subscription":{"plan":"Ultra","monthly_credits":220}}"#,
            engine: engine)
        #expect(partial.primary == nil)
        #expect(partial.details.flatMap(\.rows).map(\.label) == ["Monthly grant"])
        #expect(partial.details.flatMap(\.rows).map(\.value) == ["$220.00"])
    }

    @Test(
        arguments: ["true", "false", "\"NaN\"", "\"Infinity\"", "\"\"", "[]", "{}", "1e400"],
        BundledPluginTestSupport.engines)
    func `invalid amounts fail instead of publishing exact zero`(
        value: String,
        engine: ProviderPluginEngineKind) async throws
    {
        do {
            _ = try await Self.fetch("{\"purchased_credits_remaining\":\(value)}", engine: engine)
            Issue.record("Malformed amount was accepted")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        }
    }

    @Test(arguments: ["null", "[]", "{}", "{\"subscription\":{}}"], BundledPluginTestSupport.engines)
    func `empty account responses stay unavailable`(body: String, engine: ProviderPluginEngineKind) async throws {
        do {
            _ = try await Self.fetch(body, engine: engine)
            Issue.record("Empty account was accepted")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `requests use the declared origin token and deadline`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "nous",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://preview.nousresearch.com/api/oauth/account")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                #expect(request.timeoutInterval == 15)
                return try Self.response(request, body: Self.account)
            })
        _ = try await runtime.fetchUsage(
            settings: ["PORTAL_URL": "https://preview.nousresearch.com"],
            secrets: ["NOUS_PORTAL_ACCESS_TOKEN": "fixture-token"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `expired server sessions defer renewal to Hermes`(engine: ProviderPluginEngineKind) async throws {
        do {
            _ = try await Self.fetch("{}", engine: engine, status: 401)
            Issue.record("Unauthorized request succeeded")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
            #expect(error.message.contains("Run `hermes`"))
        }
    }

    static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind,
        status: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "nous",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request, body: body, status: status)
            })
        return try await runtime.fetchUsage(
            settings: ["PORTAL_URL": "https://portal.nousresearch.com"],
            secrets: ["NOUS_PORTAL_ACCESS_TOKEN": "fixture-token"])
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200) throws -> (Data, URLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
}
