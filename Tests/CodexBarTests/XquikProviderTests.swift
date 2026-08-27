import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct XquikProviderTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `credits fixture preserves arbitrary precision totals`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"""
        {
          "balance":"9007199254740993",
          "lifetime_purchased":"18014398509481986",
          "lifetime_used":"9007199254740992",
          "auto_topup_enabled":true,
          "auto_topup_amount_dollars":10,
          "auto_topup_threshold":"50000"
        }
        """#, engine: engine)

        #expect(snapshot.primary == RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "9,007,199,254,740,993 credits available"))
        #expect(snapshot.identity?.providerID == .xquik)
        #expect(snapshot.identity?.loginMethod == "API key")
        #expect(snapshot.dataConfidence == .exact)
        #expect(try snapshot.details == [ProviderDetailSection(
            title: "Credit usage",
            rows: [
                .init(label: "Available", value: "9,007,199,254,740,993 credits"),
                .init(label: "Lifetime used", value: "9,007,199,254,740,992 credits"),
                .init(label: "Lifetime purchased", value: "18,014,398,509,481,986 credits"),
                .init(label: "Automatic top-up", value: "Enabled", secondaryValue: "$10.00 at 50,000 credits"),
            ])])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero balance renders as exhausted without a top-up detail`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"""
        {
          "balance":"000",
          "lifetime_purchased":"1000",
          "lifetime_used":"1000",
          "auto_topup_enabled":false,
          "auto_topup_amount_dollars":0,
          "auto_topup_threshold":"0"
        }
        """#, engine: engine)

        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.primary?.resetDescription == "0 credits available")
        #expect(snapshot.details.first?.rows.last?.value == "Disabled")
        #expect(snapshot.details.first?.rows.last?.secondaryValue == nil)
    }

    @Test(arguments: [
        #"{"balance":1,"lifetime_purchased":"1","lifetime_used":"0","auto_topup_enabled":false,"auto_topup_amount_dollars":0,"auto_topup_threshold":"0"}"#,
        #"{"balance":"-1","lifetime_purchased":"1","lifetime_used":"0","auto_topup_enabled":false,"auto_topup_amount_dollars":0,"auto_topup_threshold":"0"}"#,
        #"{"balance":"1","lifetime_purchased":"1","lifetime_used":"0","auto_topup_enabled":"no","auto_topup_amount_dollars":0,"auto_topup_threshold":"0"}"#,
        #"{"balance":"1","lifetime_purchased":"1","lifetime_used":"0","auto_topup_enabled":false,"auto_topup_amount_dollars":-1,"auto_topup_threshold":"0"}"#,
    ], BundledPluginTestSupport.engines)
    func `malformed credits payload fails closed`(
        body: String,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.parseFailure, contains: "Xquik") {
            try await Self.fetch(body, engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `oversized credit strings fail before display formatting`(engine: ProviderPluginEngineKind) async {
        let body = """
        {
          "balance":"\(String(repeating: "9", count: 85))",
          "lifetime_purchased":"1",
          "lifetime_used":"0",
          "auto_topup_enabled":false,
          "auto_topup_amount_dollars":0,
          "auto_topup_threshold":"0"
        }
        """

        await Self.expectFailure(.parseFailure, contains: "at most 84 digits") {
            try await Self.fetch(body, engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `plugin calls the documented endpoint with an x-api-key header`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://xquik.com/api/v1/credits")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "xq_test")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return try Self.response(request: request, body: Self.standardFixture)
        }
        let runtime = try BundledPluginTestSupport.runtime("xquik", engine: engine, transport: transport)

        let snapshot = try await runtime.fetchUsage(secrets: ["XQUIK_API_KEY": "xq_test"])

        #expect(snapshot.primary?.resetDescription == "50,000 credits available")
    }

    @Test(arguments: [
        (401, "", ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, "forbidden", .authenticationExpired),
        (402, "payment required", .apiFailure),
        (429, "<html>slow down</html>", .rateLimited),
        (503, "<html>unavailable</html>", .providerUnavailable),
    ], BundledPluginTestSupport.engines)
    func `HTTP failures are classified before body parsing`(
        argument: (Int, String, ProviderFetchClassifiedError.Kind),
        engine: ProviderPluginEngineKind) async
    {
        let (statusCode, body, expectedKind) = argument
        await Self.expectFailure(
            expectedKind,
            contains: statusCode == 401 || statusCode == 403
                ? "Xquik API key was rejected."
                : "Xquik credits API error: HTTP \(statusCode)")
        {
            try await Self.fetch(body, engine: engine, statusCode: statusCode)
        }
    }

    @Test(arguments: ["", "not-json", "<html>not JSON</html>"], BundledPluginTestSupport.engines)
    func `successful malformed bodies are parse failures`(
        body: String,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.parseFailure, contains: "response was not valid JSON") {
            try await Self.fetch(body, engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `transport errors remain network failures`(engine: ProviderPluginEngineKind) async {
        let runtime: ProviderPluginRuntime
        do {
            runtime = try BundledPluginTestSupport.runtime(
                "xquik",
                engine: engine,
                transport: ProviderHTTPTransportHandler { _ in
                    throw URLError(.cannotConnectToHost)
                })
        } catch {
            Issue.record("Could not load Xquik plugin: \(error)")
            return
        }

        await Self.expectFailure(.networkFailure, contains: "Xquik network error") {
            try await runtime.fetchUsage(secrets: ["XQUIK_API_KEY": "fixture-key"])
        }
    }

    @Test
    func `descriptor and credential adapter expose the API integration`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .xquik)
        #expect(descriptor.metadata.displayName == "Xquik")
        #expect(descriptor.metadata.dashboardURL == "https://xquik.com")
        #expect(descriptor.metadata.sessionLabel == "Credits")
        #expect(descriptor.metadata.widgetSelectable == false)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-xquik")

        let key = XquikSettingsReader.apiKeyEnvironmentKey
        #expect(XquikSettingsReader.apiKey(environment: [key: "  xq_test  "]) == "xq_test")
        #expect(ProviderTokenResolver.resolution(for: .xquik, environment: [key: "xq_test"])?.token == "xq_test")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .xquik))

        let config = ProviderConfig(id: .xquik, apiKey: "config-key")
        let configured = ProviderConfigEnvironment.applyAPIKeyOverride(base: [:], provider: .xquik, config: config)
        #expect(configured[key] == "config-key")
        let overridden = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [key: "env-key"],
            provider: .xquik,
            config: config)
        #expect(overridden[key] == "env-key")
    }

    private static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind,
        statusCode: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "xquik",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request: request, body: body, statusCode: statusCode)
            })
        return try await runtime.fetchUsage(secrets: ["XQUIK_API_KEY": "fixture-key"])
    }

    private static func response(
        request: URLRequest,
        body: String,
        statusCode: Int = 200) throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        contains message: String,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected \(kind.rawValue) failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(error.message.contains(message))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static let standardFixture = #"""
    {
      "balance":"50000",
      "lifetime_purchased":"140000",
      "lifetime_used":"90000",
      "auto_topup_enabled":false,
      "auto_topup_amount_dollars":10,
      "auto_topup_threshold":"50000"
    }
    """#
}
