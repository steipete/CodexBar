import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ZenMuxProviderTests {
    @Test
    func `subscription and balance map to quota windows and USD PAYG`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer management-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(url.scheme == "https")
            #expect(url.host == "zenmux.ai")
            #expect(url.port == nil)
            #expect(url.user == nil)
            #expect(url.password == nil)
            #expect(url.query == nil)
            #expect(url.fragment == nil)
            switch url.path {
            case "/api/v1/management/subscription/detail":
                #expect(url.absoluteString == "https://zenmux.ai/api/v1/management/subscription/detail")
                return Self.response(url: url, body: Self.subscriptionFixture)
            case "/api/v1/management/payg/balance":
                #expect(url.absoluteString == "https://zenmux.ai/api/v1/management/payg/balance")
                return Self.response(
                    url: url,
                    body: Self.balanceFixture)
            default:
                throw URLError(.badURL)
            }
        }

        let result = try await ZenMuxUsageFetcher.fetchUsage(
            "management-key",
            includePaygBalance: true,
            transport: transport,
            now: now)
        let usage = result.usage.toUsageSnapshot(paygBalanceUSD: result.paygBalanceUSD)

        #expect(abs((usage.primary?.usedPercent ?? 0) - 7.15) < 0.0001)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetDescription == "57.20 / 800 flows")
        #expect(abs((usage.secondary?.usedPercent ?? 0) - 6.73) < 0.0001)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.resetDescription == "416.11 / 6182 flows")
        #expect(usage.loginMethod(for: .zenmux) == "Ultra plan")
        #expect(usage.subscriptionRenewsAt == nil)
        #expect(usage.subscriptionExpiresAt == Self.date("2026-04-12T08:26:56.000Z"))
        #expect(usage.providerCost?.used == 482.74)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.providerCost?.period == "ZenMux PAYG balance")
        #expect(result.paygBalanceUSD == 482.74)
    }

    @Test
    func `unhealthy account status is included in identity`() async throws {
        let body = Self.subscriptionFixture.replacingOccurrences(
            of: #""account_status": "healthy""#,
            with: #""account_status": "monitored""#)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: body)
        }

        let result = try await ZenMuxUsageFetcher.fetchUsage(
            "management-key",
            includePaygBalance: false,
            transport: transport)

        #expect(result.usage.toUsageSnapshot().loginMethod(for: .zenmux) == "Ultra plan · Monitored")
        #expect(result.paygBalanceUSD == nil)
    }

    @Test
    func `balance failure does not discard subscription usage`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/subscription/detail") {
                return Self.response(url: url, body: Self.subscriptionFixture)
            }
            return Self.response(url: url, body: #"{"error":"unavailable"}"#, statusCode: 500)
        }

        let result = try await ZenMuxUsageFetcher.fetchUsage(
            "management-key",
            includePaygBalance: true,
            transport: transport)

        #expect(abs((result.usage.toUsageSnapshot().primary?.usedPercent ?? 0) - 7.15) < 0.0001)
        #expect(result.paygBalanceUSD == nil)
    }

    @Test
    func `balance auth failure is not hidden`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/subscription/detail") {
                return Self.response(url: url, body: Self.subscriptionFixture)
            }
            return Self.response(url: url, body: #"{"error":"unauthorized"}"#, statusCode: 401)
        }

        await #expect {
            _ = try await ZenMuxUsageFetcher.fetchUsage(
                "management-key",
                includePaygBalance: true,
                transport: transport)
        } throws: { error in
            error as? ZenMuxUsageError == .authenticationRejected
        }
    }

    @Test
    func `balance cancellation is preserved`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/subscription/detail") {
                return Self.response(url: url, body: Self.subscriptionFixture)
            }
            throw URLError(.cancelled)
        }

        await #expect {
            _ = try await ZenMuxUsageFetcher.fetchUsage(
                "management-key",
                includePaygBalance: true,
                transport: transport)
        } throws: { error in
            error is CancellationError
        }
    }

    @Test
    func `missing and invalid credentials fail clearly`() async {
        await #expect {
            _ = try await ZenMuxUsageFetcher.fetchUsage(
                "  ",
                includePaygBalance: false)
        } throws: { error in
            error as? ZenMuxUsageError == .notConfigured
        }

        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: #"{"error":"unauthorized"}"#, statusCode: 403)
        }
        await #expect {
            _ = try await ZenMuxUsageFetcher.fetchUsage(
                "wrong-key",
                includePaygBalance: false,
                transport: transport)
        } throws: { error in
            error as? ZenMuxUsageError == .authenticationRejected
        }
    }

    @Test
    func `malformed subscription payload fails parsing`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(url: url, body: #"{"success":true,"data":{"plan":{}}}"#)
        }

        await #expect {
            _ = try await ZenMuxUsageFetcher.fetchUsage(
                "management-key",
                includePaygBalance: false,
                transport: transport)
        } throws: { error in
            guard case .parseFailed = error as? ZenMuxUsageError else { return false }
            return true
        }
    }

    @Test
    func `non USD PAYG balance is ignored without discarding quota usage`() async throws {
        let nonUSDBalance = Self.balanceFixture.replacingOccurrences(
            of: #""currency": "usd""#,
            with: #""currency": "eur""#)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(
                url: url,
                body: url.path.hasSuffix("/payg/balance") ? nonUSDBalance : Self.subscriptionFixture)
        }

        let result = try await ZenMuxUsageFetcher.fetchUsage(
            "management-key",
            includePaygBalance: true,
            transport: transport)

        #expect(result.paygBalanceUSD == nil)
        #expect(abs((result.usage.toUsageSnapshot().primary?.usedPercent ?? 0) - 7.15) < 0.0001)
    }

    @Test
    func `negative overdue PAYG balance remains visible`() async throws {
        let overdueBalance = Self.balanceFixture.replacingOccurrences(
            of: #""total_credits": 482.74"#,
            with: #""total_credits": -12.34"#)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(
                url: url,
                body: url.path.hasSuffix("/payg/balance") ? overdueBalance : Self.subscriptionFixture)
        }

        let result = try await ZenMuxUsageFetcher.fetchUsage(
            "management-key",
            includePaygBalance: true,
            transport: transport)
        let snapshot = result.usage.toUsageSnapshot(paygBalanceUSD: result.paygBalanceUSD)

        #expect(result.paygBalanceUSD == -12.34)
        #expect(snapshot.providerCost?.used == -12.34)
    }

    @Test
    func `settings reader trims quotes`() {
        #expect(ZenMuxSettingsReader.managementAPIKey(environment: [
            ZenMuxSettingsReader.managementAPIKeyEnvironmentKey: "  'management-key'  ",
        ]) == "management-key")
        #expect(ZenMuxSettingsReader.managementAPIKey(environment: [:]) == nil)
    }

    @Test @MainActor
    func `descriptor and app registry include ZenMux`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .zenmux)
        #expect(descriptor.metadata.displayName == "ZenMux")
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(!descriptor.metadata.supportsCredits)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])

        let implementation = try #require(ProviderImplementationRegistry.implementation(for: .zenmux))
        #expect(implementation is ZenMuxProviderImplementation)
    }

    @Test @MainActor
    func `menu card uses compact flow expiry and USD PAYG labels`() async throws {
        let now = try #require(Self.date("2026-03-24T07:35:09.000Z"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.response(
                url: url,
                body: url.path.hasSuffix("/payg/balance") ? Self.balanceFixture : Self.subscriptionFixture)
        }
        let result = try await ZenMuxUsageFetcher.fetchUsage(
            "management-key",
            includePaygBalance: true,
            transport: transport,
            now: now)
        let snapshot = result.usage.toUsageSnapshot(paygBalanceUSD: result.paygBalanceUSD)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .zenmux,
            metadata: ZenMuxProviderDescriptor.descriptor.metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first { $0.id == "primary" })
        let secondary = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(primary.detailLeftText == "57.20 / 800 flows")
        #expect(primary.detailRightText == nil)
        #expect(primary.resetText == "Resets in 1h")
        #expect(secondary.detailLeftText == "416.11 / 6182 flows")
        #expect(secondary.detailRightText == nil)
        #expect(model.usageNotes == ["Plan expires: Apr 12, 2026"])
        #expect(model.creditsText == nil)
        #expect(model.providerCost?.title == "Pay-as-you-go")
        #expect(model.providerCost?.spendLine == "Balance: $482.74")
    }

    private static let subscriptionFixture = #"""
    {
      "success": true,
      "data": {
        "plan": {
          "tier": "ultra",
          "amount_usd": 200,
          "interval": "month",
          "expires_at": "2026-04-12T08:26:56.000Z"
        },
        "currency": "usd",
        "base_usd_per_flow": 0.03283,
        "effective_usd_per_flow": 0.03283,
        "account_status": "healthy",
        "quota_5_hour": {
          "usage_percentage": 0.0715,
          "resets_at": "2026-03-24T08:35:09.000Z",
          "max_flows": 800,
          "used_flows": 57.2,
          "remaining_flows": 742.8,
          "used_value_usd": 1.88,
          "max_value_usd": 26.27
        },
        "quota_7_day": {
          "usage_percentage": 0.0673,
          "resets_at": "2026-03-26T02:15:05.000Z",
          "max_flows": 6182,
          "used_flows": 416.11,
          "remaining_flows": 5765.89,
          "used_value_usd": 13.66,
          "max_value_usd": 202.99
        },
        "quota_monthly": {
          "max_flows": 34560,
          "max_value_usd": 1134.33
        }
      }
    }
    """#

    private static let balanceFixture = #"""
    {
      "success": true,
      "data": {
        "currency": "usd",
        "total_credits": 482.74,
        "top_up_credits": 35,
        "bonus_credits": 447.74
      }
    }
    """#

    private static func response(
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

    private static func date(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
}
