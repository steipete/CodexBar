#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import CodexBarCore

struct XquikProviderTests {
    @Test
    func `credits fixture preserves arbitrary precision totals`() async throws {
        let snapshot = try await Self.fetch(#"""
        {
          "balance":"9007199254740993",
          "lifetime_purchased":"18014398509481986",
          "lifetime_used":"9007199254740992",
          "auto_topup_enabled":true,
          "auto_topup_amount_dollars":10,
          "auto_topup_threshold":"50000"
        }
        """#)

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

    @Test
    func `zero balance renders as exhausted without a top-up detail`() async throws {
        let snapshot = try await Self.fetch(#"""
        {
          "balance":"000",
          "lifetime_purchased":"1000",
          "lifetime_used":"1000",
          "auto_topup_enabled":false,
          "auto_topup_amount_dollars":0,
          "auto_topup_threshold":"0"
        }
        """#)

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
    ])
    func `malformed credits payload fails closed`(_ body: String) async throws {
        await #expect(throws: ProviderPluginError.self) {
            _ = try await Self.fetch(body)
        }
    }

    @Test
    func `oversized credit strings fail before display formatting`() async throws {
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

        await #expect(throws: ProviderPluginError.self) {
            _ = try await Self.fetch(body)
        }
    }

    @Test
    func `plugin calls the documented endpoint with an x-api-key header`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://xquik.com/api/v1/credits")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "xq_test")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return try Self.response(request: request, body: Self.standardFixture)
        }
        let runtime = try ProviderPluginRuntime(bundledPlugin: "xquik", transport: transport)

        let snapshot = try await runtime.fetchUsage(secrets: ["XQUIK_API_KEY": "xq_test"])

        #expect(snapshot.primary?.resetDescription == "50,000 credits available")
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .authenticationExpired),
        (402, .apiFailure),
        (429, .rateLimited),
        (503, .providerUnavailable),
    ])
    func `HTTP failures are classified before credits parsing`(
        argument: (Int, ProviderFetchClassifiedError.Kind)) async throws
    {
        let (statusCode, expectedKind) = argument
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "xquik",
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request: request, body: #"{"error":"fixture"}"#, statusCode: statusCode)
            })

        do {
            _ = try await runtime.fetchUsage(secrets: ["XQUIK_API_KEY": "fixture-key"])
            Issue.record("Expected \(expectedKind.rawValue) failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == expectedKind)
            if statusCode == 401 || statusCode == 403 {
                #expect(error.message == "Xquik API key was rejected.")
            } else {
                #expect(error.message == "Xquik credits API error: HTTP \(statusCode)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
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

    private static func fetch(_ body: String) async throws -> UsageSnapshot {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "xquik",
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request: request, body: body)
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
#endif
