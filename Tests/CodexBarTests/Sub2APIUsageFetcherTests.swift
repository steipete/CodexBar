import CodexBarCore
import Foundation
import Testing

struct Sub2APIUsageFetcherTests {
    @Test
    func `parses quota limited key usage`() throws {
        let json = """
        {
          "mode": "quota_limited",
          "isValid": true,
          "status": "active",
          "remaining": 75,
          "unit": "USD",
          "quota": {
            "limit": 100,
            "used": 25,
            "remaining": 75,
            "unit": "USD"
          },
          "rate_limits": [
            {
              "window": "5h",
              "limit": 20,
              "used": 5,
              "remaining": 15,
              "reset_at": "2026-07-11T12:30:00Z"
            },
            {
              "window": "7d",
              "limit": 200,
              "used": 40,
              "remaining": 160
            }
          ],
          "expires_at": "2026-08-01T00:00:00Z",
          "usage": {
            "today": {
              "requests": 4,
              "total_tokens": 1200,
              "actual_cost": 1.25
            },
            "total": {
              "requests": 40,
              "total_tokens": 12000,
              "actual_cost": 25
            }
          }
        }
        """

        let parsed = try Sub2APIUsageFetcher._parseSnapshotForTesting(
            Data(json.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))

        #expect(parsed.mode == "quota_limited")
        #expect(parsed.quota?.remaining == 75)
        #expect(parsed.rateLimits.count == 2)
        #expect(parsed.todayUsage?.totalTokens == 1200)

        let snapshot = parsed.toUsageSnapshot()
        #expect(snapshot.identity?.providerID == .sub2api)
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.extraRateWindows?.count == 2)
        #expect(snapshot.extraRateWindows?.first?.window.windowMinutes == 300)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.sub2APIUsage?.kind == .keyQuota)
        #expect(snapshot.sub2APIUsage?.today?.requests == 4)
        #expect(snapshot.sub2APIUsage?.today?.totalTokens == 1200)
        #expect(snapshot.sub2APIUsage?.today?.actualCostUSD == 1.25)
        #expect(snapshot.sub2APIUsage?.total?.requests == 40)
        #expect(snapshot.subscriptionExpiresAt != nil)
        #expect(snapshot.dataConfidence == .exact)

        let roundTripped = try JSONDecoder().decode(
            UsageSnapshot.self,
            from: JSONEncoder().encode(snapshot))
        let relabeled = roundTripped.withIdentity(ProviderIdentitySnapshot(
            providerID: .sub2api,
            accountEmail: "Group A",
            accountOrganization: nil,
            loginMethod: nil))
        #expect(relabeled.sub2APIUsage == snapshot.sub2APIUsage)
    }

    @Test
    func `parses subscription usage windows`() throws {
        let json = """
        {
          "mode": "unrestricted",
          "isValid": true,
          "planName": "Claude Team",
          "remaining": 8,
          "unit": "USD",
          "subscription": {
            "daily_usage_usd": 2,
            "weekly_usage_usd": 10,
            "monthly_usage_usd": 30,
            "daily_limit_usd": 10,
            "weekly_limit_usd": 40,
            "monthly_limit_usd": 100,
            "expires_at": "2026-08-15T00:00:00.123Z"
          }
        }
        """

        let parsed = try Sub2APIUsageFetcher._parseSnapshotForTesting(
            Data(json.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 20)
        #expect(snapshot.secondary?.usedPercent == 25)
        #expect(snapshot.tertiary?.usedPercent == 30)
        #expect(snapshot.identity?.accountOrganization == "Claude Team")
        #expect(snapshot.identity?.loginMethod == "Claude Team")
        #expect(snapshot.sub2APIUsage?.kind == .subscription)
        #expect(snapshot.subscriptionExpiresAt != nil)
    }

    @Test
    func `preserves authoritative subscription windows when daily usage differs`() throws {
        let json = """
        {
          "mode": "unrestricted",
          "subscription": {
            "daily_usage_usd": 120.23,
            "weekly_usage_usd": 229.20,
            "monthly_usage_usd": 1296.23,
            "daily_limit_usd": 120,
            "weekly_limit_usd": 700,
            "monthly_limit_usd": 2800
          },
          "daily_usage": [
            { "date": "2026-07-05", "actual_cost": 229.20 }
          ]
        }
        """

        let parsed = try Sub2APIUsageFetcher._parseSnapshotForTesting(
            Data(json.utf8),
            updatedAt: self.localDate(year: 2026, month: 7, day: 8))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.secondary?.usedPercent == 229.20 / 700 * 100)
        #expect(snapshot.tertiary?.usedPercent == 1296.23 / 2800 * 100)
        #expect(snapshot.primary?.resetDescription == "$120.23 / $120.00")
        #expect(snapshot.secondary?.resetDescription == "$229.20 / $700.00")
    }

    @Test
    func `does not reinterpret subscription windows as local calendar periods`() throws {
        let json = """
        {
          "mode": "unrestricted",
          "subscription": {
            "daily_usage_usd": 99,
            "weekly_usage_usd": 99,
            "monthly_usage_usd": 30,
            "daily_limit_usd": 10,
            "weekly_limit_usd": 40,
            "monthly_limit_usd": 100
          },
          "daily_usage": [
            { "date": "2026-07-05", "actual_cost": 50 },
            { "date": "2026-07-06", "actual_cost": 4 },
            { "date": "2026-07-08", "actual_cost": 2 }
          ]
        }
        """

        let parsed = try Sub2APIUsageFetcher._parseSnapshotForTesting(
            Data(json.utf8),
            updatedAt: self.localDate(year: 2026, month: 7, day: 8))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.secondary?.usedPercent == 100)
        #expect(snapshot.tertiary?.usedPercent == 30)
        #expect(snapshot.primary?.resetDescription == "$99.00 / $10.00")
        #expect(snapshot.secondary?.resetDescription == "$99.00 / $40.00")
    }

    @Test
    func `parses unrestricted wallet balance`() throws {
        let json = """
        {
          "mode": "unrestricted",
          "isValid": true,
          "planName": "Wallet plan",
          "remaining": 42.5,
          "unit": "USD",
          "balance": 42.5
        }
        """

        let parsed = try Sub2APIUsageFetcher._parseSnapshotForTesting(
            Data(json.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.loginMethod == "Wallet plan")
        #expect(snapshot.sub2APIUsage?.kind == .wallet)
        #expect(snapshot.sub2APIUsage?.balance == 42.5)
    }

    @Test
    func `usage URL accepts root versioned and complete URLs`() throws {
        #expect(
            try Sub2APIUsageFetcher
                ._usageURLForTesting(baseURL: #require(URL(string: "https://api.example.com")))
                .absoluteString == "https://api.example.com/v1/usage")
        #expect(
            try Sub2APIUsageFetcher
                ._usageURLForTesting(baseURL: #require(URL(string: "https://api.example.com/v1")))
                .absoluteString == "https://api.example.com/v1/usage")
        #expect(
            try Sub2APIUsageFetcher
                ._usageURLForTesting(baseURL: #require(URL(string: "https://api.example.com/v1/usage")))
                .absoluteString == "https://api.example.com/v1/usage")
    }

    @Test
    func `fetch sends bearer API key`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let requestURL = try #require(request.url)
            #expect(requestURL.path == "/v1/usage")
            let queryItems = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            #expect(queryItems.contains(URLQueryItem(name: "days", value: "30")))
            #expect(queryItems.contains(URLQueryItem(name: "timezone", value: TimeZone.current.identifier)))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-group")
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(#"{"mode":"unrestricted","isValid":true,"balance":5}"#.utf8), response)
        }

        let snapshot = try await Sub2APIUsageFetcher.fetchUsage(
            apiKey: "sk-group",
            baseURL: #require(URL(string: "https://api.example.com")),
            transport: transport)

        #expect(snapshot.balance == 5)
    }

    @Test
    func `fetch enforces total request deadline`() async throws {
        let transport = ProviderHTTPTransportHandler { _ in
            try await Task.sleep(for: .seconds(60))
            throw URLError(.unknown)
        }

        await #expect(throws: URLError.self) {
            try await Sub2APIUsageFetcher.fetchUsage(
                apiKey: "sk-group",
                baseURL: #require(URL(string: "https://api.example.com")),
                transport: transport,
                timeout: .milliseconds(10))
        }
    }

    @Test
    func `fetch rejects invalid key in successful response`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(#"{"mode":"unrestricted","isValid":false}"#.utf8), response)
        }

        await #expect(throws: Sub2APIUsageError.invalidCredentials) {
            try await Sub2APIUsageFetcher.fetchUsage(
                apiKey: "sk-revoked",
                baseURL: #require(URL(string: "https://api.example.com")),
                transport: transport)
        }
    }

    @Test
    func `settings allow HTTPS and loopback HTTP only`() {
        #expect(Sub2APISettingsReader.baseURL(environment: [
            Sub2APISettingsReader.baseURLEnvironmentKey: "https://api.example.com",
        ]) != nil)
        #expect(Sub2APISettingsReader.baseURL(environment: [
            Sub2APISettingsReader.baseURLEnvironmentKey: "http://127.0.0.1:8080",
        ]) != nil)
        #expect(Sub2APISettingsReader.baseURL(environment: [
            Sub2APISettingsReader.baseURLEnvironmentKey: "http://api.example.com",
        ]) == nil)
        #expect(Sub2APISettingsReader.baseURL(environment: [
            Sub2APISettingsReader.baseURLEnvironmentKey: "https://user:pass@api.example.com",
        ]) == nil)
        #expect(Sub2APISettingsReader.baseURL(environment: [
            Sub2APISettingsReader.baseURLEnvironmentKey: "https://api.example.com?token=secret",
        ]) == nil)
        #expect(Sub2APISettingsReader.baseURL(environment: [
            Sub2APISettingsReader.baseURLEnvironmentKey: "https://api.example.com#fragment",
        ]) == nil)
    }

    @Test
    func `provider config projects API key and base URL`() {
        let config = ProviderConfig(
            id: .sub2api,
            apiKey: "sk-fallback",
            enterpriseHost: "https://api.example.com")
        let environment = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .sub2api,
            config: config)

        #expect(environment[Sub2APISettingsReader.apiKeyEnvironmentKey] == "sk-fallback")
        #expect(environment[Sub2APISettingsReader.baseURLEnvironmentKey] == "https://api.example.com")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .sub2api))
    }

    @Test
    func `supports labeled group API key accounts`() throws {
        let support = try #require(TokenAccountSupportCatalog.support(for: .sub2api))
        #expect(support.title == "Group API keys")
        #expect(TokenAccountSupportCatalog.envOverride(for: .sub2api, token: "sk-claude") == [
            Sub2APISettingsReader.apiKeyEnvironmentKey: "sk-claude",
        ])
    }

    private func localDate(year: Int, month: Int, day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12)))
    }
}
