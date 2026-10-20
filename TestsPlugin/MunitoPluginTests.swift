import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct MunitoPluginTests {
    /// Documented `GET /admin/v1/limits` schema with synthetic values, plus the optional organization read.
    static let limitsFixture =
        #"{"object":"spend_limits","usage_tier":"fixture-tier","periods":["#
            + #"{"period":"day","spent_usd":4.25,"limit_usd":50,"organization_limit_usd":500,"account_limit_usd":40,"#
            + #""stopped_until":null},"#
            + #"{"period":"month","spent_usd":123.4,"limit_usd":1000,"organization_limit_usd":5000,"#
            + #""account_limit_usd":900}]}"#
    static let organizationFixture =
        #"{"object":"organization","id":"org_fixture","name":"Fixture Org","status":"active","#
            + #""usage_tier":"fixture-tier","data_region":"eu","created_at":"2026-01-01T00:00:00Z"}"#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `spend windows, cost, details, and organization are parsed`(engine: ProviderPluginEngineKind) async throws {
        // Model a fixture delayed past the production optional collection budget.
        let snapshot = try await Self.fetch(engine: engine, organizationDelay: .milliseconds(300))
        let primary = try #require(snapshot.primary)
        let secondary = try #require(snapshot.secondary)
        #expect(primary.usedPercent == 8.5)
        #expect(primary.windowMinutes == 1440)
        #expect(primary.resetsAt == nil)
        #expect(abs(secondary.usedPercent - 12.34) < 0.000_001)
        #expect(secondary.windowMinutes == nil)
        let cost = try #require(snapshot.providerCost)
        #expect(cost.used == 123.4)
        #expect(cost.limit == 1000)
        #expect(cost.currencyCode == "USD")
        #expect(cost.period == "This month")
        let sections = snapshot.details
        #expect(sections.map(\.title) == ["Spend limits", "Organization"])
        let spendRows = try #require(sections.first).rows
        #expect(spendRows.map(\.label) == [
            "Today",
            "Today organization limit",
            "Today account limit",
            "This month",
            "This month organization limit",
            "This month account limit",
            "Usage tier",
        ])
        #expect(spendRows[0].value == "$4.25 of $50.00")
        #expect(abs((spendRows[0].progress?.usedPercent ?? -1) - 8.5) < 0.000_001)
        #expect(spendRows[0].usageValue == 4.25)
        #expect(spendRows[1].value == "$500.00")
        #expect(spendRows[2].value == "$40.00")
        #expect(spendRows[3].value == "$123.40 of $1,000.00")
        #expect(spendRows[6].value == "fixture-tier")
        let organizationRows = sections.last?.rows ?? []
        #expect(organizationRows.map(\.label) == ["Status", "Data region"])
        #expect(organizationRows.map(\.value) == ["Active", "eu"])
        #expect(snapshot.identity?.loginMethod == "Admin API key")
        #expect(snapshot.identity?.accountOrganization == "Fixture Org")
        #expect(snapshot.identity?.accountID == "org_fixture")
        #expect(snapshot.identity?.accountEmail == nil)
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.subscriptionRenewsAt == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `periods without limits keep spend-only rows and no windows`(engine: ProviderPluginEngineKind) async throws {
        let body = #"{"object":"spend_limits","periods":[{"period":"day","spent_usd":2,"limit_usd":null},"#
            + #"{"period":"month","spent_usd":"12.75","limit_usd":0}]}"#
        let snapshot = try await Self.fetch(body, engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost?.used == 12.75)
        #expect(snapshot.providerCost?.limit == 0)
        let rows = try #require(snapshot.details.first).rows
        #expect(rows.map(\.label) == ["Today", "This month", "Usage tier"])
        #expect(rows[0].value == "$2.00")
        #expect(rows[0].progress == nil)
        #expect(rows[1].value == "$12.75")
        #expect(rows[2].value == "fixture-tier")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a missing month period reports the day cost as Today`(engine: ProviderPluginEngineKind) async throws {
        let body = #"{"object":"spend_limits","periods":[{"period":"day","spent_usd":3.5,"limit_usd":35}]}"#
        let snapshot = try await Self.fetch(body, engine: engine)
        #expect(snapshot.primary?.usedPercent == 10)
        #expect(snapshot.providerCost?.used == 3.5)
        #expect(snapshot.providerCost?.limit == 35)
        #expect(snapshot.providerCost?.period == "Today")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unknown periods are ignored and stopped spend keeps its date`(engine: ProviderPluginEngineKind) async throws {
        let body = #"{"object":"spend_limits","periods":["#
            + #"{"period":"quarter","spent_usd":999,"limit_usd":5000},"#
            + #"{"period":"day","spent_usd":50,"limit_usd":50,"stopped_until":"2030-01-01T00:00:00Z"}]}"#
        let snapshot = try await Self.fetch(body, engine: engine)
        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.providerCost?.period == "Today")
        let labels = snapshot.details.flatMap { $0.rows.map(\.label) }
        #expect(labels.contains("Today stopped until"))
        let row = try #require(snapshot.details.flatMap(\.rows).first { $0.label == "Today stopped until" })
        #expect(row.value == "2030-01-01T00:00:00.000Z")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `daily and monthly spending stops retain their separate times`(engine: ProviderPluginEngineKind) async throws {
        let body = #"""
        {"periods":[
          {"period":"day","spent_usd":50,"limit_usd":50,"stopped_until":"2030-01-02T08:30:00Z"},
          {"period":"month","spent_usd":500,"limit_usd":500,"stopped_until":"2030-02-01T00:00:00Z"}]}
        """#
        let snapshot = try await Self.fetch(body, engine: engine)
        let stops = snapshot.details.flatMap(\.rows).filter { $0.label.hasSuffix("stopped until") }
        #expect(stops.map(\.label) == ["Today stopped until", "This month stopped until"])
        #expect(stops.map(\.value) == ["2030-01-02T08:30:00.000Z", "2030-02-01T00:00:00.000Z"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `an unavailable organization read keeps spend and limits`(engine: ProviderPluginEngineKind) async throws {
        for organization in ["private-response", "null", "[]"] {
            let snapshot = try await Self.fetch(
                Self.limitsFixture, engine: engine, organizationBody: organization, organizationCode: 200)
            #expect(snapshot.primary?.usedPercent == 8.5)
            #expect(snapshot.providerCost?.used == 123.4)
            #expect(snapshot.identity?.accountOrganization == nil)
            #expect(snapshot.identity?.loginMethod == "Admin API key")
            #expect(snapshot.details.map(\.title) == ["Spend limits"])
        }
        let snapshot = try await Self.fetch(Self.limitsFixture, engine: engine, organizationCode: 500)
        #expect(snapshot.primary?.usedPercent == 8.5)
        #expect(snapshot.identity?.accountID == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `empty periods keep an identity-only card`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"{"object":"spend_limits","periods":[]}"#, engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.details.map(\.title) == [Optional("Spend limits"), Optional("Organization")])
        #expect(snapshot.details.first?.rows.map(\.label) == ["Usage tier"])
        #expect(snapshot.identity?.loginMethod == "Admin API key")
        #expect(snapshot.identity?.accountOrganization == "Fixture Org")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed bodies fail closed`(engine: ProviderPluginEngineKind) async {
        for body in [
            "private-response",
            "null",
            "[]",
            "42",
            #"{}"#,
            #"{"object":"spend_limits"}"#,
            #"{"periods":{}}"#,
            #"{"periods":"private-response"}"#,
            #"{"periods":["private-response"]}"#,
            #"{"periods":[{"period":"day","spent_usd":"private-response","limit_usd":5}]}"#,
            #"{"periods":[{"period":"day","spent_usd":-1,"limit_usd":5}]}"#,
            #"{"periods":[{"period":"day","spent_usd":1,"limit_usd":"private-response"}]}"#,
            #"{"periods":[{"period":"day","spent_usd":1,"limit_usd":5,"stopped_until":"yesterday"}]}"#,
        ] {
            await Self.expectFailure(body, engine: engine, kind: .parseFailure) { message in
                #expect(message.contains("unrecognized") || message.contains("unusable"))
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP errors retain classification without echoing private bodies`(engine: ProviderPluginEngineKind) async {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            await Self.expectFailure(
                "private-response", engine: engine, code: code, kind: kind)
            { message in
                if code == 403 { #expect(message.contains("Read account data")) }
            }
        }
    }

    @Test
    func `credentials stay explicit, aliased, and provider defaults off`() throws {
        let descriptor = MunitoProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(credentials.resolveToken(environment: ["MUNITO_API_KEY": "fixture-key"])?.token == "fixture-key")
        #expect(credentials.resolveToken(environment: ["MUNITO_ADMIN_KEY": "fixture-key"])?.token == "fixture-key")
        #expect(credentials.resolveToken(environment: ["MUNITO_ADMIN_KEY": " 'alias' "])?.token == "alias")
        #expect(credentials.resolveToken(environment: ["MUNITO_API_KEY": "  "]) == nil)
        #expect(credentials.resolveToken(environment: ["OTHER_API_KEY": "fixture-key"]) == nil)
    }

    private static func expectFailure(
        _ body: String,
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        kind: ProviderFetchClassifiedError.Kind,
        message check: (String) -> Void = { _ in }) async
    {
        do {
            _ = try await self.fetch(body, engine: engine, code: code)
            Issue.record("Expected classified failure for \(body)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
            #expect(!error.message.contains("fixture-key"))
            check(error.message)
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    static func fetch(
        _ body: String = Self.limitsFixture,
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        organizationBody: String = Self.organizationFixture,
        organizationCode: Int = 200,
        organizationDelay: Duration = .zero) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "munito", engine: engine, transport: ProviderHTTPTransportHandler { request in
                let path = request.url?.path ?? ""
                if path.hasSuffix("/organization") { try await Task.sleep(for: organizationDelay) }
                #expect(request.url?.host == "api.munito.ai")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                let (text, status): (String, Int) =
                    path.hasSuffix("/limits") ? (body, code) : (organizationBody, organizationCode)
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                return (Data(text.utf8), response)
            },
            contextOptions: ProviderPluginContextOptions(
                optionalRequestTimeoutSeconds: nil,
                waitForOptionalDeadline: { _, _ in
                    // Parser fixtures must not race the production 200 ms collection deadline.
                    let (pending, release) = AsyncStream<Void>.makeStream()
                    defer { release.finish() }
                    for await _ in pending {}
                    try Task.checkCancellation()
                }))
        return try await runtime.fetchUsage(secrets: ["MUNITO_API_KEY": "fixture-key"])
    }
}
