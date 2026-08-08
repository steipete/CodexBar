import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ProviderPluginParityTests {
    @Test
    func `cut-over providers use only JS without the prototype flag`() async {
        for (provider, key) in [
            (UsageProvider.crof, "CROF_API_KEY"),
            (.venice, "VENICE_API_KEY"),
            (.openrouter, "OPENROUTER_API_KEY"),
            (.clawrouter, "CLAWROUTER_API_KEY"),
            (.deepgram, "DEEPGRAM_API_KEY"),
            (.poe, "POE_API_KEY"),
            (.sub2api, "SUB2API_API_KEY"),
            (.synthetic, "SYNTHETIC_API_KEY"),
            (.xai, "XAI_MANAGEMENT_API_KEY"),
            (.zai, "Z_AI_API_KEY"),
        ] {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            var environment = [key: "fixture-key"]
            if provider == .sub2api {
                environment[Sub2APISettingsReader.baseURLEnvironmentKey] = "https://api.example.com"
            }
            if provider == .xai {
                environment[XAISettingsReader.teamIDEnvironmentKey] = "team-1234"
            }
            let context = Self.context(environment: environment)
            let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)

            #expect(strategies.map(\.id) == ["\(provider.rawValue).js"])
            #expect(await strategies[0].isAvailable(context))
            environment[ProviderPluginPrototype.environmentKey] = "1"
            let flagged = await descriptor.fetchPlan.pipeline.resolveStrategies(Self.context(environment: environment))
            #expect(flagged.map(\.id) == ["\(provider.rawValue).js"])
        }
    }

    @Test(arguments: [UsageProvider.openrouter, .clawrouter, .deepgram])
    func `override preflight preserves provider validation errors`(provider: UsageProvider) async throws {
        let environment: [String: String] = switch provider {
        case .openrouter:
            [
                OpenRouterSettingsReader.envKey: "fixture-key",
                OpenRouterSettingsReader.apiURLEnvironmentKey: "http://router.example.test",
                ProviderPluginPrototype.environmentKey: "1",
            ]
        case .clawrouter:
            [
                ClawRouterSettingsReader.apiKeyEnvironmentKey: "fixture-key",
                ClawRouterSettingsReader.baseURLEnvironmentKey: "http://router.example.test",
                ProviderPluginPrototype.environmentKey: "1",
            ]
        case .deepgram:
            [
                DeepgramSettingsReader.apiKeyEnvironmentKey: "fixture-key",
                DeepgramSettingsReader.apiURLEnvironmentKey: "http://router.example.test",
                ProviderPluginPrototype.environmentKey: "1",
            ]
        default: [:]
        }
        let context = Self.context(environment: environment)
        let strategy = try #require(await ProviderDescriptorRegistry.descriptor(for: provider)
            .fetchPlan.pipeline.resolveStrategies(context).first)

        do {
            _ = try await strategy.fetch(context)
            Issue.record("Expected invalid endpoint override")
        } catch let error as OpenRouterSettingsError {
            #expect(provider == .openrouter)
            #expect(error == .invalidEndpointOverride(OpenRouterSettingsReader.apiURLEnvironmentKey))
        } catch let error as ClawRouterSettingsError {
            #expect(provider == .clawrouter)
            #expect(error == .invalidEndpointOverride(ClawRouterSettingsReader.baseURLEnvironmentKey))
        } catch let error as DeepgramSettingsError {
            #expect(provider == .deepgram)
            guard case let .invalidEndpointOverride(key) = error else {
                Issue.record("Unexpected Deepgram settings error: \(error)")
                return
            }
            #expect(key == DeepgramSettingsReader.apiURLEnvironmentKey)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `Synthetic fixture matches the cut-over golden`() async throws {
        let body = """
        {
          "plan": "Starter",
          "weeklyTokenLimit": {
            "nextRegenAt": "2026-04-17T05:19:30.000Z",
            "percentRemaining": 98.05884722222223,
            "maxCredits": "$36.00",
            "remainingCredits": "$35.30",
            "nextRegenCredits": "$0.72"
          },
          "rollingFiveHourLimit": {
            "nextTickAt": "2026-04-17T03:44:11.000Z",
            "tickPercent": 0.05,
            "remaining": 600,
            "max": 750,
            "limited": false
          },
          "search": {
            "hourly": {
              "limit": 250,
              "requests": 2,
              "renewsAt": "2026-04-17T04:30:01.494Z"
            }
          }
        }
        """
        let transport = Self.transport(body: body)
        let now = Date(timeIntervalSince1970: 1_775_000_000)

        let runtime = try ProviderPluginRuntime(bundledPlugin: "synthetic", transport: transport)
        let script = try await runtime.fetchUsage(secrets: ["SYNTHETIC_API_KEY": "fixture-key"], now: now)

        #expect(script.primary == RateWindow(
            usedPercent: 20,
            windowMinutes: nil,
            resetsAt: Date(timeIntervalSince1970: 1_776_397_451),
            resetDescription: nil,
            nextRegenPercent: 5))
        #expect(script.secondary == RateWindow(
            usedPercent: 1.9411527777777735,
            windowMinutes: nil,
            resetsAt: Date(timeIntervalSince1970: 1_776_403_170),
            resetDescription: nil))
        #expect(script.tertiary == RateWindow(
            usedPercent: 0.8,
            windowMinutes: nil,
            resetsAt: Date(timeIntervalSince1970: 1_776_400_201.494),
            resetDescription: nil))
        #expect(script.providerCost?.used == 0.7000000000000028)
        #expect(script.providerCost?.limit == 36)
        #expect(script.providerCost?.currencyCode == "USD")
        #expect(script.providerCost?.period == "Weekly")
        #expect(script.providerCost?.resetsAt == Date(timeIntervalSince1970: 1_776_403_170))
        #expect(script.providerCost?.nextRegenAmount == 0.72)
        #expect(script.identity?.providerID == .synthetic)
        #expect(script.identity?.accountEmail == nil)
        #expect(script.identity?.accountOrganization == nil)
        #expect(script.identity?.loginMethod == "Starter")
        #expect(script.identity?.accountID == nil)
    }

    @Test
    func `Venice fixture matches the cut-over golden`() async throws {
        let body = """
        {
          "canConsume": true,
          "consumptionCurrency": "BUNDLED_CREDITS",
          "balances": { "diem": "50.0", "usd": "10.0" },
          "diemEpochAllocation": "100.0"
        }
        """
        let transport = Self.transport(body: body)
        let now = Date(timeIntervalSince1970: 1_775_000_000)

        let runtime = try ProviderPluginRuntime(bundledPlugin: "venice", transport: transport)
        let script = try await runtime.fetchUsage(secrets: ["VENICE_API_KEY": "fixture-key"], now: now)

        #expect(script.primary == RateWindow(
            usedPercent: 50,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "DIEM 50.00 / 100.00 epoch allocation"))
        #expect(script.secondary == nil)
        #expect(script.tertiary == nil)
        #expect(script.providerCost == nil)
        #expect(script.identity?.providerID == .venice)
        #expect(script.identity?.accountEmail == nil)
        #expect(script.identity?.accountOrganization == nil)
        #expect(script.identity?.loginMethod == nil)
    }

    @Test
    func `Crof fixture matches the cut-over golden`() async throws {
        let body = #"{"credits":9.9999,"requests_plan":1000,"usable_requests":998}"#
        let transport = Self.transport(body: body)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetchStartedAt = Date()

        let runtime = try ProviderPluginRuntime(bundledPlugin: "crof", transport: transport)
        let script = try await runtime.fetchUsage(secrets: ["CROF_API_KEY": "fixture-key"], now: now)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let reset = try #require(calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: fetchStartedAt)))
        #expect(script.primary == RateWindow(
            usedPercent: 1,
            windowMinutes: 1440,
            resetsAt: reset,
            resetDescription: "998 requests left"))
        #expect(script.secondary == RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "$9.99"))
        #expect(script.tertiary == nil)
        #expect(script.providerCost == nil)
        #expect(script.identity?.providerID == .crof)
        #expect(script.identity?.loginMethod == "API key")
    }

    @Test
    func `OpenRouter monthly limit fixture matches the cut-over golden`() async throws {
        let creditsBody = #"{"data":{"total_credits":100,"total_usage":40}}"#
        let keyBody = #"""
        {"data":{
          "limit":500,
          "limit_remaining":454.542594979,
          "limit_reset":"monthly",
          "usage":433.286754736,
          "usage_daily":3.404645509,
          "usage_weekly":3.404645509,
          "usage_monthly":45.457405021
        }}
        """#
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            if request.url?.path.hasSuffix("/key") == true {
                try await Task.sleep(for: .milliseconds(950))
            }
            let body = request.url?.path.hasSuffix("/key") == true ? keyBody : creditsBody
            return (Data(body.utf8), response)
        }
        let now = Date()

        let runtime = try Self.openRouterRuntime(transport: transport)
        let script = try await runtime.fetchUsage(
            secrets: ["OPENROUTER_API_KEY": "fixture-key"],
            now: now)

        #expect(script.primary?.usedPercent == 9.0914810042)
        #expect(script.identity?.providerID == .openrouter)
        #expect(script.identity?.loginMethod == "Balance: $60.00")
    }

    @Test
    func `OpenRouter remaining above limit fixture matches the cut-over golden`() async throws {
        let creditsBody = #"{"data":{"total_credits":100,"total_usage":40}}"#
        let keyBody = #"""
        {"data":{
          "limit":500,
          "limit_remaining":512.25,
          "limit_reset":"monthly",
          "usage":0,
          "usage_daily":0,
          "usage_weekly":0,
          "usage_monthly":0
        }}
        """#
        let transport = ProviderHTTPTransportHandler { request in
            if request.url?.path.hasSuffix("/key") == true {
                try await Task.sleep(for: .milliseconds(950))
            }
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            let body = request.url?.path.hasSuffix("/key") == true ? keyBody : creditsBody
            return (Data(body.utf8), response)
        }
        let now = Date()

        let runtime = try Self.openRouterRuntime(transport: transport)
        let script = try await runtime.fetchUsage(
            secrets: ["OPENROUTER_API_KEY": "fixture-key"],
            now: now)

        // Server remaining above the configured limit clamps to a full quota (0% used)
        // in both implementations instead of suppressing the meter.
        #expect(script.primary?.usedPercent == 0)
        #expect(script.detailRow(label: "API key remaining")?.value == "$500.00")
    }

    @Test
    func `OpenRouter reset window fallback without cumulative usage matches the cut-over golden`() async throws {
        let creditsBody = #"{"data":{"total_credits":100,"total_usage":40}}"#
        let keyBody = #"""
        {"data":{
          "limit":500,
          "limit_reset":"monthly",
          "usage_monthly":45.457405021
        }}
        """#
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            if request.url?.path.hasSuffix("/key") == true {
                try await Task.sleep(for: .milliseconds(950))
            }
            let body = request.url?.path.hasSuffix("/key") == true ? keyBody : creditsBody
            return (Data(body.utf8), response)
        }
        let now = Date()

        let runtime = try Self.openRouterRuntime(transport: transport)
        let script = try await runtime.fetchUsage(
            secrets: ["OPENROUTER_API_KEY": "fixture-key"],
            now: now)

        // Without cumulative usage, the reset-window fallback still renders the meter
        // in both implementations.
        #expect(script.primary?.usedPercent == 9.0914810042)
        #expect(script.detailRow(label: "API key remaining")?.value == "$454.54")
    }

    private static func transport(body: String) -> ProviderHTTPTransportHandler {
        ProviderHTTPTransportHandler { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
    }

    private static func openRouterRuntime(
        transport: any ProviderHTTPTransport) throws -> ProviderPluginRuntime
    {
        try ProviderPluginRuntime(
            bundledPlugin: "openrouter",
            transport: transport,
            contextOptions: ProviderPluginContextOptions(optionalRequestTimeoutSeconds: 15))
    }

    private static func context(environment: [String: String]) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ProviderPluginParityClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}

private struct ProviderPluginParityClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String {
        "unused"
    }

    func detectVersion() -> String? {
        nil
    }
}
