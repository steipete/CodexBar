import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct Sub2APIPluginGoldenTests {
    @Test
    func `quota limited fixture matches the production golden`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "mode": "quota_limited",
          "isValid": true,
          "status": "active",
          "remaining": 75,
          "unit": "USD",
          "quota": { "limit": 100, "used": 25, "remaining": 75, "unit": "USD" },
          "rate_limits": [
            { "window": "5h", "limit": 20, "used": 5, "remaining": 15,
              "reset_at": "2026-07-11T12:30:00Z" },
            { "window": "7d", "limit": 200, "used": 40, "remaining": 160 }
          ],
          "expires_at": "2026-08-01T00:00:00Z",
          "usage": {
            "today": { "requests": 4, "total_tokens": 1200, "actual_cost": 1.25 },
            "total": { "requests": 40, "total_tokens": 12000, "actual_cost": 25 }
          }
        }
        """)

        #expect(snapshot.identity?.providerID == .sub2api)
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.extraRateWindows?.count == 2)
        #expect(snapshot.extraRateWindows?.first?.window.windowMinutes == 300)
        #expect(snapshot.detailRow(label: "Today requests")?.value == "4")
        #expect(snapshot.detailRow(label: "Today tokens")?.value == "1,200")
        #expect(snapshot.detailRow(label: "Today tokens")?.secondaryValue == "$1.25")
        #expect(snapshot.detailRow(label: "All time requests")?.value == "40")
        #expect(snapshot.subscriptionExpiresAt != nil)
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test
    func `subscription windows remain authoritative and grouped`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "mode": "unrestricted",
          "planName": "Claude Team",
          "subscription": {
            "daily_usage_usd": 120.23,
            "weekly_usage_usd": 229.20,
            "monthly_usage_usd": 1296.23,
            "daily_limit_usd": 120,
            "weekly_limit_usd": 700,
            "monthly_limit_usd": 2800,
            "expires_at": "2026-08-15T00:00:00.123Z"
          },
          "daily_usage": [{ "date": "2026-07-05", "actual_cost": 229.20 }]
        }
        """)

        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.secondary?.usedPercent == 229.20 / 700 * 100)
        #expect(snapshot.tertiary?.usedPercent == 1296.23 / 2800 * 100)
        #expect(snapshot.primary?.resetDescription == "$120.23 / $120.00")
        #expect(snapshot.tertiary?.resetDescription == "$1,296.23 / $2,800.00")
        #expect(snapshot.identity?.loginMethod == "Claude Team")
    }

    @Test(arguments: [
        "https://api.example.com",
        "https://api.example.com/v1",
        "https://api.example.com/v1/usage",
    ])
    func `request shape and hard deadline match the native golden`(baseURL: String) async throws {
        let recorder = Sub2APIRequestRecorder()
        _ = try await Self.fetch(
            #"{"mode":"unrestricted","isValid":true,"balance":5}"#,
            baseURL: baseURL,
            recorder: recorder)

        let request = try #require(await recorder.requests.first)
        #expect(request.url?.path == "/v1/usage")
        let queryItems = try URLComponents(url: #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(queryItems.contains(URLQueryItem(name: "days", value: "30")))
        // Foundation says "GMT" where JS Intl says "UTC" on UTC-configured machines; both are the
        // same zone, so accept either alias instead of the exact identifier.
        let sentTimezone = try #require(queryItems.first { $0.name == "timezone" }?.value)
        let currentIdentifier = TimeZone.current.identifier
        let zeroOffsetAliases: Set = ["GMT", "UTC", "Etc/UTC", "Etc/GMT"]
        #expect(
            sentTimezone == currentIdentifier
                || (zeroOffsetAliases.contains(sentTimezone) && zeroOffsetAliases.contains(currentIdentifier)))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(request.timeoutInterval == 15)
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .authenticationExpired),
        (429, .rateLimited),
        (500, .providerUnavailable),
        (400, .apiFailure),
    ])
    func `HTTP failures preserve classified surface`(
        status: Int,
        kind: ProviderFetchClassifiedError.Kind) async throws
    {
        do {
            _ = try await Self.fetch("not-json", status: status)
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `invalid key parse and network failures keep classifications`() async throws {
        await Self.expectFailure(.authenticationExpired) {
            try await Self.fetch(#"{"mode":"unrestricted","isValid":false}"#)
        }
        await Self.expectFailure(.parseFailure) {
            try await Self.fetch(#"{"quota":{"limit":"many"}}"#)
        }
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "sub2api",
            transport: ProviderHTTPTransportHandler { _ in throw URLError(.notConnectedToInternet) })
        await Self.expectFailure(.networkFailure) {
            try await runtime.fetchUsage(
                settings: [Sub2APISettingsReader.baseURLEnvironmentKey: "https://api.example.com"],
                secrets: [Sub2APISettingsReader.apiKeyEnvironmentKey: "fixture-key"])
        }
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected \(kind.rawValue) failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func fetch(
        _ body: String,
        status: Int = 200,
        baseURL: String = "https://api.example.com",
        recorder: Sub2APIRequestRecorder? = nil) async throws -> UsageSnapshot
    {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "sub2api",
            transport: ProviderHTTPTransportHandler { request in
                if let recorder {
                    await recorder.append(request)
                }
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(
            settings: [Sub2APISettingsReader.baseURLEnvironmentKey: baseURL],
            secrets: [Sub2APISettingsReader.apiKeyEnvironmentKey: "fixture-key"])
    }
}

private actor Sub2APIRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.requests.append(request)
    }
}
