import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ChutesProviderTests {
    @Test
    func `settings reader trims quoted API key`() {
        let token = ChutesSettingsReader.apiKey(environment: [
            ChutesSettingsReader.apiKeyEnvironmentKey: " 'chutes-test' ",
        ])

        #expect(token == "chutes-test")
    }

    @Test
    func `config API key projects into Chutes environment`() {
        let config = ProviderConfig(id: .chutes, apiKey: "chutes-config-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .chutes,
            config: config)

        #expect(env[ChutesSettingsReader.apiKeyEnvironmentKey] == "chutes-config-token")
        #expect(ChutesSettingsReader.apiKey(environment: env) == "chutes-config-token")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .chutes))
    }

    @Test
    func `fetch usage maps active subscription monthly and rolling windows`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rollingReset = try Self.date("2026-06-13T18:00:00Z")
        let monthlyReset = try Self.date("2026-07-01T00:00:00Z")
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path == "/users/me/subscription_usage")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer chutes-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 15)

            let body = #"""
            {
              "subscription": {
                "active": true,
                "plan_name": "Pro",
                "current_period_end": "2026-07-01T00:00:00Z"
              },
              "monthly": {
                "used": 250,
                "limit": 1000,
                "resets_at": "2026-07-01T00:00:00Z",
                "unit": "credits"
              },
              "rolling_window": {
                "requests": 40,
                "limit": 100,
                "window_minutes": 240,
                "reset_at": "2026-06-13T18:00:00Z",
                "unit": "requests"
              }
            }
            """#
            return Self.makeResponse(url: url, body: body)
        }

        let snapshot = try await ChutesUsageFetcher.fetchUsage(
            apiKey: " chutes-key ",
            environment: [ChutesSettingsReader.apiURLEnvironmentKey: "https://chutes.test"],
            transport: transport,
            now: now)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 40)
        #expect(usage.primary?.windowMinutes == 240)
        #expect(usage.primary?.resetsAt == rollingReset)
        #expect(usage.primary?.resetDescription == "40/100 requests")
        #expect(usage.secondary?.usedPercent == 25)
        #expect(usage.secondary?.resetsAt == monthlyReset)
        #expect(usage.secondary?.resetDescription == "250/1000 credits")
        #expect(usage.subscriptionRenewsAt == monthlyReset)
        #expect(usage.loginMethod(for: .chutes) == "Pro")

        let requests = await transport.requests()
        #expect(requests.count == 1)
    }

    @Test
    func `no active subscription falls back to quotas endpoint`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            switch url.path {
            case "/users/me/subscription_usage":
                return Self.makeResponse(url: url, body: #"""
                {
                  "subscription": {
                    "active": false,
                    "status": "free"
                  }
                }
                """#)
            case "/users/me/quotas":
                return Self.makeResponse(url: url, body: #"""
                [
                  {
                    "chute_id": "0",
                    "is_default": true,
                    "quota": 100
                  }
                ]
                """#)
            case "/users/me/quota_usage/0":
                return Self.makeResponse(url: url, body: #"""
                {
                  "quota": 100,
                  "used": 10
                }
                """#)
            default:
                throw URLError(.badURL)
            }
        }

        let snapshot = try await ChutesUsageFetcher.fetchUsage(
            apiKey: "chutes-key",
            environment: [ChutesSettingsReader.apiURLEnvironmentKey: "https://chutes.test"],
            transport: transport,
            now: now)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 10)
        #expect(usage.primary?.resetDescription == "10/100 credits")
        #expect(usage.secondary == nil)
        #expect(usage.loginMethod(for: .chutes) == "No active subscription")

        let requests = await transport.requests()
        let paths = requests.compactMap { $0.url?.path }
        #expect(paths == [
            "/users/me/subscription_usage",
            "/users/me/quotas",
            "/users/me/quota_usage/0",
        ])
    }

    @Test
    func `wrapped quota list fetches per quota usage`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            switch url.path {
            case "/users/me/subscription_usage":
                return Self.makeResponse(url: url, body: #"{"subscription":{"active":false}}"#)
            case "/users/me/quotas":
                return Self.makeResponse(url: url, body: #"""
                {
                  "data": [
                    {
                      "chute_id": "wrapped",
                      "quota": 200
                    }
                  ]
                }
                """#)
            case "/users/me/quota_usage/wrapped":
                return Self.makeResponse(url: url, body: #"{"quota":200,"used":50}"#)
            default:
                throw URLError(.badURL)
            }
        }

        let snapshot = try await ChutesUsageFetcher.fetchUsage(
            apiKey: "chutes-key",
            environment: [ChutesSettingsReader.apiURLEnvironmentKey: "https://chutes.test"],
            transport: transport)

        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 25)
        let requests = await transport.requests()
        #expect(requests.compactMap { $0.url?.path } == [
            "/users/me/subscription_usage",
            "/users/me/quotas",
            "/users/me/quota_usage/wrapped",
        ])
    }

    @Test
    func `partial subscription usage fills missing rolling window from quotas`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            switch url.path {
            case "/users/me/subscription_usage":
                return Self.makeResponse(url: url, body: #"""
                {
                  "subscription": {
                    "active": true,
                    "plan_name": "Pro",
                    "current_period_end": "2026-07-01T00:00:00Z"
                  },
                  "monthly": {
                    "used": 250,
                    "limit": 1000,
                    "unit": "credits"
                  }
                }
                """#)
            case "/users/me/quotas":
                return Self.makeResponse(url: url, body: #"""
                {
                  "rolling_window": {
                    "requests": 40,
                    "limit": 100,
                    "window_minutes": 240,
                    "unit": "requests"
                  }
                }
                """#)
            default:
                throw URLError(.badURL)
            }
        }

        let snapshot = try await ChutesUsageFetcher.fetchUsage(
            apiKey: "chutes-key",
            environment: [ChutesSettingsReader.apiURLEnvironmentKey: "https://chutes.test"],
            transport: transport,
            now: now)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 40)
        #expect(usage.primary?.windowMinutes == 240)
        #expect(usage.primary?.resetDescription == "40/100 requests")
        #expect(usage.secondary?.usedPercent == 25)
        #expect(usage.secondary?.resetDescription == "250/1000 credits")
        #expect(usage.loginMethod(for: .chutes) == "Pro")

        let requests = await transport.requests()
        let paths = requests.compactMap { $0.url?.path }
        #expect(paths == ["/users/me/subscription_usage", "/users/me/quotas"])
    }

    @Test
    func `missing usage fields returns no data snapshot without decode failure`() throws {
        let data = Data(#"{"subscription":{"active":true},"unexpected":{"nested":true}}"#.utf8)
        let snapshot = try ChutesUsageParser.parse(data: data, now: Date(timeIntervalSince1970: 123))
        let usage = snapshot.toUsageSnapshot()

        #expect(!snapshot.hasUsageData)
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.loginMethod(for: .chutes) == nil)
    }

    @Test
    func `identical usage values keep distinct quota windows`() throws {
        let data = Data(#"""
        {
          "quotas": [
            {
              "used": 0,
              "limit": 100,
              "window_minutes": 240
            },
            {
              "used": 0,
              "limit": 100,
              "window_minutes": 43200
            }
          ]
        }
        """#.utf8)

        let snapshot = try ChutesUsageParser.parse(data: data, now: Date(timeIntervalSince1970: 123))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.windowMinutes == 240)
        #expect(usage.secondary?.usedPercent == 0)
        #expect(usage.secondary?.windowMinutes == 43200)
    }

    @Test
    func `exact percent value of one stays one percent`() throws {
        let usedData = Data(#"""
        {
          "rolling_window": {
            "usage_percent": 1
          }
        }
        """#.utf8)
        let remainingData = Data(#"""
        {
          "rolling_window": {
            "percent_remaining": 1
          }
        }
        """#.utf8)

        let usedSnapshot = try ChutesUsageParser.parse(
            data: usedData,
            now: Date(timeIntervalSince1970: 123))
        let remainingSnapshot = try ChutesUsageParser.parse(
            data: remainingData,
            now: Date(timeIntervalSince1970: 123))

        #expect(usedSnapshot.toUsageSnapshot().primary?.usedPercent == 1)
        #expect(remainingSnapshot.toUsageSnapshot().primary?.usedPercent == 99)
    }

    @Test
    func `auth failure surfaces invalid credentials`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.makeResponse(url: url, body: #"{"detail":"unauthorized"}"#, statusCode: 401)
        }

        await #expect {
            _ = try await ChutesUsageFetcher.fetchUsage(
                apiKey: "bad-key",
                environment: [ChutesSettingsReader.apiURLEnvironmentKey: "https://chutes.test"],
                transport: transport)
        } throws: { error in
            guard case ChutesUsageError.invalidCredentials = error else { return false }
            return true
        }
    }

    @Test
    func `descriptor and app implementation registry include Chutes`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .chutes)
        #expect(descriptor.metadata.displayName == "Chutes")
        #expect(ProviderDescriptorRegistry.all.contains { $0.id == .chutes })

        let implementation = try #require(ProviderImplementationRegistry.implementation(for: .chutes))
        #expect(implementation is ChutesProviderImplementation)
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }

    private static func date(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: text))
    }
}
