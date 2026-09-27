import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct AnyRouterPluginTests {
    /// The documented example payload from https://docs.anyrouter.dev/api-reference/credits.
    static let documented = payload()

    static func payload(
        balance: String = "9.734035",
        monthly: String = "7.5",
        topup: String = "2.234035",
        used: String = "0.265965",
        today: String = "0.042",
        currency: String = "usd") -> String
    {
        let fields = [
            "\"balance\":\(balance)",
            "\"monthly_balance\":\(monthly)",
            "\"topup_balance\":\(topup)",
            "\"used\":\(used)",
            "\"today_cost\":\(today)",
            "\"currency\":\"\(currency)\"",
        ]
        return "{" + fields.joined(separator: ",") + "}"
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `documented credits render as exact rows without an invented quota`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(engine: engine)

        // A prepaid balance is not a rate window, so no window or cost may be fabricated.
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.identity?.providerID == .anyrouter)
        #expect(snapshot.identity?.loginMethod == "API key")

        let rows = try #require(snapshot.details.first?.rows)
        #expect(rows.map(\.label) == [
            "Available balance",
            "Plan credits",
            "Top-up credits",
            "Lifetime spend",
            "Spent today (UTC)",
        ])
        #expect(rows.map(\.value) == ["$9.73", "$7.50", "$2.23", "$0.27", "$0.04"])
        #expect(rows.map(\.usageValue) == [9.734035, 7.5, 2.234035, 0.265965, 0.042])
    }

    @Test(arguments: ["0", "-0.01", "0.000001"], BundledPluginTestSupport.engines)
    func `remaining balance is reported exactly as the gateway reports it`(
        balance: String, engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(engine: engine, body: Self.payload(balance: balance))

        #expect(snapshot.details.first?.rows.first?.usageValue == Double(balance))
    }

    @Test(arguments: [
        #"{"balance":1,"monthly_balance":-1,"topup_balance":0,"used":0,"today_cost":0,"currency":"usd"}"#,
        #"{"balance":1,"monthly_balance":0,"topup_balance":-1,"used":0,"today_cost":0,"currency":"usd"}"#,
        #"{"balance":1,"monthly_balance":0,"topup_balance":0,"used":-1,"today_cost":0,"currency":"usd"}"#,
        #"{"balance":1,"monthly_balance":0,"topup_balance":0,"used":0,"today_cost":-1,"currency":"usd"}"#,
    ], BundledPluginTestSupport.engines)
    func `negative accumulations are impossible and fail closed`(
        body: String, engine: ProviderPluginEngineKind) async
    {
        await #expect(throws: ProviderFetchClassifiedError.self) {
            try await Self.fetch(engine: engine, body: body)
        }
    }

    @Test(arguments: ["eur", "USD", "", "usd "], BundledPluginTestSupport.engines)
    func `only the documented USD credit currency is accepted`(
        currency: String, engine: ProviderPluginEngineKind) async
    {
        await #expect(throws: ProviderFetchClassifiedError.self) {
            try await Self.fetch(engine: engine, body: Self.payload(currency: currency))
        }
    }

    @Test(arguments: [
        "",
        " ",
        "not-json",
        "null",
        "[]",
        "{}",
        #"{"balance":"9.73","monthly_balance":7.5,"topup_balance":2.23,"used":0.26,"today_cost":0,"currency":"usd"}"#,
        #"{"balance":9.73,"monthly_balance":7.5,"topup_balance":2.23,"used":0.26,"currency":"usd"}"#,
        #"{"balance":null,"monthly_balance":7.5,"topup_balance":2.23,"used":0.26,"today_cost":0,"currency":"usd"}"#,
        #"{"balance":true,"monthly_balance":7.5,"topup_balance":2.23,"used":0.26,"today_cost":0,"currency":"usd"}"#,
        #"{"balance":1e400,"monthly_balance":7.5,"topup_balance":2.23,"used":0.26,"today_cost":0,"currency":"usd"}"#,
    ], BundledPluginTestSupport.engines)
    func `malformed payloads fail closed without echoing response data`(
        body: String, engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(engine: engine, body: body)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
            #expect(!error.message.contains("private"))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .permissionDenied),
        (429, .rateLimited),
        (503, .providerUnavailable),
        (400, .apiFailure),
    ], BundledPluginTestSupport.engines)
    func `HTTP failures expose status without response bodies`(
        fixture: (Int, ProviderFetchClassifiedError.Kind), engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, code: fixture.0, body: "private-response fixture-key")
            Issue.record("Expected HTTP failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == fixture.1)
            #expect(error.localizedDescription.contains(String(fixture.0)))
            #expect(!error.localizedDescription.contains("private-response"))
            #expect(!error.localizedDescription.contains("fixture-key"))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a scoped out key is reported as a scope problem with the documented fix`(
        engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(engine: engine, code: 403, body: "private-response")
            Issue.record("Expected permission failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .permissionDenied)
            // A dashboard key ships with an endpoint allow-list that omits /api/v1/credits,
            // so the message has to name the fix rather than implying a bad credential.
            #expect(error.message.contains("Management permissions"))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test
    func `registry keeps AnyRouter an opt in balance provider`() throws {
        let descriptor = AnyRouterProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        let spec = AnyRouterProviderDescriptor.spec

        #expect(descriptor.metadata.displayName == "AnyRouter")
        #expect(descriptor.metadata.balanceOnly)
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(!descriptor.metadata.widgetSelectable)
        #expect(descriptor.metadata.dashboardURL == "https://dash.anyrouter.dev")
        #expect(descriptor.branding.color == ProviderColor(hex: 0xF38020))
        #expect(spec.apiKey(environment: ["ANYROUTER_API_KEY": "fixture-key"]) == "fixture-key")
        #expect(spec.apiKey(environment: ["ANYROUTER_API_KEY": " \n"]) == nil)
        #expect(spec.apiKey(environment: ["OTHER_API_KEY": "fixture-key"]) == nil)
        #expect(credentials.resolveToken(environment: ["ANYROUTER_API_KEY": "fixture-key"])?.token == "fixture-key")
        // The settings copy has to name the Management permissions step, because a default
        // dashboard key is created without access to the credits route.
        let apiKeyField = try #require(AnyRouterProviderDescriptor.spec.apiKeyField)
        #expect(apiKeyField.subtitle.contains("Management permissions"))
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        body: String = AnyRouterPluginTests.documented) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "anyrouter",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://anyrouter.dev/api/v1/credits")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["ANYROUTER_API_KEY": "fixture-key"])
    }
}
