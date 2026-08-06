#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import CodexBarCore

struct CrofPluginGoldenTests {
    @Test
    func `credits-only fixture matches the production golden`() async throws {
        let json = """
        {
          "credits":9.0441,
          "requests_plan":null,
          "usable_requests":null,
          "usage":{
            "deepseek-v4-flash":{
              "cached_tokens":0,
              "input_tokens":23,
              "output_tokens":132,
              "total_tokens":155
            }
          }
        }
        """
        let snapshot = try await Self.fetch(json)

        #expect(snapshot.primary == RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "$9.04"))
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.providerID == .crof)
        #expect(snapshot.identity?.loginMethod == "API key")
    }

    @Test
    func `request-quota fixture matches the production golden`() async throws {
        let json = """
        {"credits":10.0,"requests_plan":1000,"usable_requests":998}
        """
        let now = Date(timeIntervalSince1970: 1_777_800_000)
        let fetchStartedAt = Date()
        let snapshot = try await Self.fetch(json, now: now)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let reset = try #require(calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: fetchStartedAt)))
        #expect(snapshot.primary == RateWindow(
            usedPercent: 1,
            windowMinutes: 1440,
            resetsAt: reset,
            resetDescription: "998 requests left"))
        #expect(snapshot.secondary == RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "$10.00"))
    }

    @Test
    func `credit balance formatting and depletion match the production goldens`() async throws {
        let funded = try await Self.fetch(#"{"credits":9.9999,"requests_plan":null,"usable_requests":null}"#)
        let depleted = try await Self.fetch(#"{"credits":0,"requests_plan":null,"usable_requests":null}"#)

        #expect(funded.primary?.usedPercent == 0)
        #expect(funded.primary?.resetDescription == "$9.99")
        #expect(depleted.primary?.usedPercent == 100)
        #expect(depleted.primary?.resetDescription == "$0.00")
    }

    @Test
    func `plugin request uses the public endpoint and bearer token`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.url?.absoluteString == "https://crof.ai/usage_api/")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer crof-test")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return try Self.response(
                request: request,
                body: #"{"credits":9.0441,"requests_plan":null,"usable_requests":null,"usage":{}}"#)
        }
        let runtime = try ProviderPluginRuntime(bundledPlugin: "crof", transport: transport)

        let snapshot = try await runtime.fetchUsage(secrets: ["CROF_API_KEY": "crof-test"])

        #expect(snapshot.primary?.resetDescription == "$9.04")
    }

    @Test
    func `descriptor supports auto and API source modes`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .crof)
        #expect(descriptor.metadata.displayName == "Crof")
        #expect(descriptor.metadata.dashboardURL == "https://crof.ai/dashboard")
        #expect(descriptor.metadata.sessionLabel == "Credits")
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-crof")
    }

    @Test
    func `settings and credential adapter preserve Crof precedence`() {
        let key = CrofSettingsReader.apiKeyEnvironmentKeys[0]
        #expect(CrofSettingsReader.apiKey(environment: [key: "  crof-token  "]) == "crof-token")
        #expect(ProviderTokenResolver.resolution(for: .crof, environment: [key: "crof-token"])?.token == "crof-token")

        let config = ProviderConfig(id: .crof, apiKey: "config-token")
        let configured = ProviderConfigEnvironment.applyAPIKeyOverride(base: [:], provider: .crof, config: config)
        #expect(configured[key] == "config-token")
        let overridden = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [key: "env-token"],
            provider: .crof,
            config: config)
        #expect(overridden[key] == "env-token")
    }

    private static func fetch(
        _ body: String,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)) async throws -> UsageSnapshot
    {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "crof",
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request: request, body: body)
            })
        return try await runtime.fetchUsage(secrets: ["CROF_API_KEY": "fixture-key"], now: now)
    }

    private static func response(request: URLRequest, body: String) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
}

enum CrofTestSnapshots {
    static func credits(_ amount: Double, updatedAt: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: amount > 0 ? 0 : 100,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: String(format: "$%.2f", floor(max(0, amount) * 100) / 100)),
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .crof,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "API key"))
    }

    static func requestQuota(
        credits: Double,
        plan: Double,
        remaining: Double,
        updatedAt: Date = Date()) -> UsageSnapshot
    {
        let clamped = max(0, min(plan, remaining))
        let remainingPercent = plan > 0 ? floor(clamped / plan * 100) : 0
        return UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100 - remainingPercent,
                windowMinutes: 1440,
                resetsAt: updatedAt.addingTimeInterval(86400),
                resetDescription: "\(Int(max(0, remaining))) requests left"),
            secondary: self.credits(credits, updatedAt: updatedAt).primary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .crof,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "API key"))
    }
}
#endif
