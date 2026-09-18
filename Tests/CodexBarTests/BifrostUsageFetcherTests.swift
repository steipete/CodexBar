import CodexBarCore
import Foundation
import Testing

struct BifrostUsageFetcherTests {
    @Test
    func `orders budgets by shortest reset cycle and builds windows`() throws {
        let json = """
        {
          "virtual_key_name": "mobile-app",
          "budgets": [
            {
              "id": "budget_year",
              "max_limit": 1000,
              "reset_duration": "1Y",
              "current_usage": 100
            },
            {
              "id": "budget_month",
              "max_limit": 125,
              "reset_duration": "1M",
              "last_reset": "2026-09-01T00:00:00Z",
              "current_usage": 42.17,
              "source_name": "Eng Tier 2"
            }
          ]
        }
        """

        let parsed = try BifrostUsageFetcher._parseQuotaForTesting(
            Data(json.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))

        let snapshot = parsed.toUsageSnapshot()
        #expect(snapshot.identity?.providerID == .bifrost)
        #expect(snapshot.identity?.accountEmail == "mobile-app")
        #expect(snapshot.identity?.accountOrganization == "Eng Tier 2")

        let primary = try #require(snapshot.primary)
        #expect(abs(primary.usedPercent - 33.736) < 0.001)
        #expect(primary.resetDescription == "Eng Tier 2 · Monthly · $42.17 / $125.00")

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let expectedReset = try #require(
            utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        #expect(primary.resetsAt == expectedReset)

        let secondary = try #require(snapshot.secondary)
        #expect(secondary.usedPercent == 10)
        #expect(secondary.resetDescription == "Yearly · $100.00 / $1,000.00")

        #expect(snapshot.providerCost?.used == 42.17)
        #expect(snapshot.providerCost?.limit == 125)
        #expect(snapshot.providerCost?.period == "Monthly")
    }

    @Test
    func `computes effective max limit from override state`() throws {
        let json = """
        {
          "budgets": [
            { "id": "forever", "max_limit": 100, "current_usage": 1,
              "override_amount": 50, "override_mode": "forever" },
            { "id": "cycles-active", "max_limit": 100, "current_usage": 1,
              "override_amount": 50, "override_mode": "cycles", "override_cycles_remaining": 2 },
            { "id": "cycles-exhausted", "max_limit": 100, "current_usage": 1,
              "override_amount": 50, "override_mode": "cycles", "override_cycles_remaining": 0 },
            { "id": "unknown-mode", "max_limit": 100, "current_usage": 1,
              "override_amount": 50, "override_mode": "paused" },
            { "id": "no-amount", "max_limit": 100, "current_usage": 1,
              "override_amount": 0, "override_mode": "forever" }
          ]
        }
        """

        let parsed = try BifrostUsageFetcher._parseQuotaForTesting(Data(json.utf8), updatedAt: Date())
        let byID = Dictionary(uniqueKeysWithValues: parsed.budgets.map { ($0.id, $0) })

        #expect(byID["forever"]?.effectiveMaxLimit == 150)
        #expect(byID["cycles-active"]?.effectiveMaxLimit == 150)
        #expect(byID["cycles-exhausted"]?.effectiveMaxLimit == 100)
        #expect(byID["unknown-mode"]?.effectiveMaxLimit == 100)
        #expect(byID["no-amount"]?.effectiveMaxLimit == 100)
    }

    @Test
    func `treats a zero limit budget as unlimited spend without a window`() throws {
        let json = """
        {
          "budgets": [
            { "id": "unlimited", "max_limit": 0, "current_usage": 5 }
          ]
        }
        """

        let parsed = try BifrostUsageFetcher._parseQuotaForTesting(Data(json.utf8), updatedAt: Date())
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost?.used == 5)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.providerCost?.period == "Spend")
    }

    @Test
    func `clamps the window percent when usage exceeds the effective limit`() throws {
        let json = """
        {
          "budgets": [
            { "id": "over", "max_limit": 100, "current_usage": 150 }
          ]
        }
        """

        let parsed = try BifrostUsageFetcher._parseQuotaForTesting(Data(json.utf8), updatedAt: Date())
        let snapshot = parsed.toUsageSnapshot()

        let primary = try #require(snapshot.primary)
        #expect(primary.usedPercent == 100)
        #expect(snapshot.providerCost?.used == 150)
        #expect(snapshot.providerCost?.limit == 100)
    }

    @Test
    func `treats a null budgets array as empty with no provider cost`() throws {
        let json = """
        { "virtual_key_name": "svc", "budgets": null }
        """

        let parsed = try BifrostUsageFetcher._parseQuotaForTesting(Data(json.utf8), updatedAt: Date())
        let snapshot = parsed.toUsageSnapshot()

        #expect(parsed.budgets.isEmpty)
        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.details.isEmpty)
    }

    @Test
    func `flags an inactive key while preserving remaining budgets`() throws {
        let json = """
        {
          "is_active": false,
          "budgets": [
            { "id": "b1", "max_limit": 100, "current_usage": 10 }
          ]
        }
        """

        let parsed = try BifrostUsageFetcher._parseQuotaForTesting(Data(json.utf8), updatedAt: Date())
        #expect(parsed.isActive == false)

        let snapshot = parsed.toUsageSnapshot()
        #expect(snapshot.primary != nil)
        let flag = try #require(snapshot.extraRateWindows?.first)
        #expect(flag.id == "bifrost-key-inactive")
        #expect(flag.usageKnown == false)
    }

    @Test
    func `throws inactiveKey when a disabled key has no budgets or rate limits`() throws {
        let json = """
        { "is_active": false, "budgets": null }
        """

        do {
            _ = try BifrostUsageFetcher._parseQuotaForTesting(Data(json.utf8), updatedAt: Date())
            Issue.record("expected BifrostUsageError.inactiveKey")
        } catch BifrostUsageError.inactiveKey {
            // expected
        } catch {
            Issue.record("expected BifrostUsageError.inactiveKey, got \(error)")
        }
    }

    @Test
    func `emits rate limit windows and dedupes by id`() throws {
        let json = """
        {
          "rate_limit": {
            "id": "rl_1",
            "token_max_limit": 1000000,
            "token_current_usage": 345678,
            "token_reset_duration": "1d",
            "request_max_limit": 5000,
            "request_current_usage": 120,
            "request_reset_duration": "1h"
          },
          "rate_limits": [
            { "id": "rl_1", "token_max_limit": 1000000, "token_current_usage": 345678 },
            { "id": "rl_2", "source_name": "Team pool", "token_max_limit": 200000,
              "token_current_usage": 100, "request_reset_duration": "1h" }
          ]
        }
        """

        let parsed = try BifrostUsageFetcher._parseQuotaForTesting(Data(json.utf8), updatedAt: Date())
        let snapshot = parsed.toUsageSnapshot()
        let windows = try #require(snapshot.extraRateWindows)

        let tokens = try #require(windows.first { $0.id == "bifrost-tokens" })
        #expect(tokens.usageKnown == true)
        #expect(tokens.window.usedPercent == 34.5678)

        let requests = try #require(windows.first { $0.id == "bifrost-requests" })
        #expect(requests.usageKnown == true)
        #expect(requests.window.usedPercent == 2.4)

        // rl_1 appears in both rate_limit and rate_limits: only the primary pair is emitted.
        #expect(windows.filter { $0.id.hasPrefix("bifrost-tokens") }.count == 2)

        let extraTokens = try #require(windows.first { $0.id == "bifrost-tokens-rl_2" })
        #expect(extraTokens.title == "Team pool Tokens")
        #expect(abs(extraTokens.window.usedPercent - 0.05) < 0.0001)

        // rl_2 has no request_max_limit but does carry reset metadata: usage is unknown, not absent.
        let extraRequests = try #require(windows.first { $0.id == "bifrost-requests-rl_2" })
        #expect(extraRequests.usageKnown == false)
        #expect(extraRequests.window.usedPercent == 0)
    }

    @Test
    func `converts oversized token and request counts without throwing`() throws {
        let json = """
        {
          "budgets": [
            { "id": "b1", "max_limit": 100, "current_usage": 10,
              "per_model_usage": [
                { "model": "gpt-4o", "provider": "openai", "total_requests": 42,
                  "total_tokens": 1e20, "total_cost": 5 }
              ]
            }
          ]
        }
        """

        let parsed = try BifrostUsageFetcher._parseQuotaForTesting(Data(json.utf8), updatedAt: Date())
        let usage = try #require(parsed.budgets.first?.perModelUsage.first)

        #expect(usage.totalRequests == 42)
        #expect(usage.totalTokens == nil)
    }

    @Test
    func `truncates per-model detail rows at the section limit`() throws {
        let entries = (0..<30).map {
            #"{ "model": "model-\#($0)", "provider": "acme", "total_cost": \#(30 - $0) }"#
        }.joined(separator: ",")
        let json = """
        {
          "budgets": [
            { "id": "b1", "max_limit": 1000, "current_usage": 10,
              "per_model_usage": [\(entries)] }
          ]
        }
        """

        let parsed = try BifrostUsageFetcher._parseQuotaForTesting(Data(json.utf8), updatedAt: Date())
        let snapshot = parsed.toUsageSnapshot()
        let section = try #require(snapshot.details.first { $0.title == "Models" })

        #expect(section.rows.count == 24)
        #expect(section.rows.first?.label == "acme · model-0")
    }

    @Test
    func `quota url is built from the governance endpoint`() throws {
        let root = try #require(URL(string: "https://bifrost.example.com"))
        let trailingSlash = try #require(URL(string: "https://bifrost.example.com/"))

        #expect(
            BifrostUsageFetcher._quotaURLForTesting(baseURL: root).absoluteString ==
                "https://bifrost.example.com/api/governance/virtual-keys/quota")
        #expect(
            BifrostUsageFetcher._quotaURLForTesting(baseURL: trailingSlash).absoluteString ==
                "https://bifrost.example.com/api/governance/virtual-keys/quota")
    }

    @Test
    func `settings reader trims quoted environment values`() {
        let environment = [
            "BIFROST_API_KEY": " 'vk-test' ",
            "BIFROST_BASE_URL": #" "https://bifrost.example.com" "#,
        ]

        #expect(BifrostSettingsReader.apiKey(environment: environment) == "vk-test")
        #expect(BifrostSettingsReader.baseURL(environment: environment)?
            .absoluteString == "https://bifrost.example.com")
    }

    @Test
    func `fetch sends the virtual key header and parses the quota response`() async throws {
        let baseURL = try #require(URL(string: "https://bifrost.example.com"))
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "x-bf-vk") == "vk-test")
            #expect(request.url?.path == "/api/governance/virtual-keys/quota")

            let body = """
            {
              "virtual_key_name": "mobile-app",
              "budgets": [
                { "id": "b1", "max_limit": 100, "current_usage": 10 }
              ]
            }
            """
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(body.utf8), response)
        }

        let snapshot = try await BifrostUsageFetcher.fetchUsage(
            apiKey: " vk-test\n",
            baseURL: baseURL,
            transport: transport)

        #expect(snapshot.virtualKeyName == "mobile-app")
        let requests = await transport.requests()
        #expect(requests.count == 1)
    }

    @Test
    func `fetch maps unauthorized and expired key responses to distinct errors`() async throws {
        let baseURL = try #require(URL(string: "https://bifrost.example.com"))

        for (statusCode, expectUnauthorized) in [(401, true), (403, false)] {
            let transport = ProviderHTTPTransportStub { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil))
                return (Data(#"{"error":"denied"}"#.utf8), response)
            }

            do {
                _ = try await BifrostUsageFetcher.fetchUsage(
                    apiKey: "vk-test",
                    baseURL: baseURL,
                    transport: transport)
                Issue.record("expected an error for status \(statusCode)")
            } catch BifrostUsageError.unauthorized {
                #expect(expectUnauthorized)
            } catch BifrostUsageError.keyExpired {
                #expect(!expectUnauthorized)
            } catch {
                Issue.record("unexpected error for status \(statusCode): \(error)")
            }
        }
    }

    @Test
    func `fetch surfaces other non-2xx responses with a body preview`() async throws {
        let baseURL = try #require(URL(string: "https://bifrost.example.com"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil))
            return (Data(#"{"error":"boom"}"#.utf8), response)
        }

        do {
            _ = try await BifrostUsageFetcher.fetchUsage(
                apiKey: "vk-test",
                baseURL: baseURL,
                transport: transport)
            Issue.record("expected BifrostUsageError.apiError")
        } catch let BifrostUsageError.apiError(message) {
            #expect(message.contains("HTTP 500"))
            #expect(message.contains("boom"))
        } catch {
            Issue.record("expected BifrostUsageError.apiError, got \(error)")
        }
    }
}
