import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct NeuralWattPluginTests {
    private static let fixtures = [
        #"""
        {
          "snapshot_at": "2026-04-16T18:30:00Z",
          "balance": {
            "credits_remaining_usd": 32.6774,
            "total_credits_usd": 52.34,
            "credits_used_usd": 19.6626,
            "accounting_method": "energy"
          },
          "usage": {
            "lifetime": {
              "cost_usd": 243.9145,
              "requests": 37801,
              "tokens": 1235477176,
              "energy_kwh": 15.6009
            },
            "current_month": {
              "cost_usd": 160.1463,
              "requests": 23902,
              "tokens": 1116658995,
              "energy_kwh": 9.7278
            }
          },
          "limits": {
            "overage_limit_usd": null,
            "rate_limit_tier": "standard"
          },
          "subscription": {
            "plan": "standard",
            "status": "active",
            "billing_interval": "month",
            "current_period_start": "2026-04-11T05:05:25Z",
            "current_period_end": "2026-05-11T05:05:25Z",
            "auto_renew": true,
            "kwh_included": 20.0,
            "kwh_used": 13.9023,
            "kwh_remaining": 6.0977,
            "in_overage": false
          },
          "key": {
            "name": "my-production-key",
            "allowance": {
              "limit_usd": 50.0,
              "period": "monthly",
              "spent_usd": 12.5,
              "remaining_usd": 37.5,
              "blocked": false
            }
          }
        }
        """#,
        #"""
        {
          "snapshot_at": "2026-04-16T18:30:00Z",
          "balance": {
            "credits_remaining_usd": 4.5,
            "total_credits_usd": 5.0,
            "credits_used_usd": 0.5,
            "accounting_method": "energy"
          },
          "usage": {
            "lifetime": {
              "cost_usd": 0.5,
              "requests": 10,
              "tokens": 1000,
              "energy_kwh": 0.01
            },
            "current_month": {
              "cost_usd": 0.5,
              "requests": 10,
              "tokens": 1000,
              "energy_kwh": 0.01
            }
          },
          "limits": {
            "overage_limit_usd": null,
            "rate_limit_tier": "free"
          },
          "subscription": null,
          "key": {
            "name": "trial",
            "allowance": null
          }
        }
        """#,
        #"""
        {
          "balance": {
            "credits_remaining_usd": 30.0,
            "total_credits_usd": 100.0,
            "accounting_method": "energy"
          },
          "usage": {
            "lifetime": {},
            "current_month": {}
          },
          "limits": {},
          "subscription": null,
          "key": {
            "name": "x",
            "allowance": null
          }
        }
        """#,
        #"""
        {
          "balance": {
            "credits_remaining_usd": 0.0,
            "total_credits_usd": 0.0,
            "accounting_method": "energy"
          },
          "usage": {
            "lifetime": {},
            "current_month": {}
          },
          "limits": {},
          "subscription": null,
          "key": {
            "name": "x",
            "allowance": null
          }
        }
        """#,
        #"""
        {
          "balance": {
            "credits_remaining_usd": 0.0,
            "total_credits_usd": 0.0,
            "accounting_method": "energy"
          },
          "usage": {
            "lifetime": {},
            "current_month": {}
          },
          "limits": {},
          "subscription": {
            "plan": "pro_energy",
            "status": "active",
            "current_period_start": "2026-04-01T00:00:00Z",
            "current_period_end": "2026-05-01T00:00:00Z",
            "kwh_included": 10.0,
            "kwh_used": 2.5,
            "kwh_remaining": 7.5
          },
          "key": {
            "name": "subscriber",
            "allowance": null
          }
        }
        """#,
        #"""
        {
          "balance": {
            "credits_remaining_usd": 1.0
          },
          "subscription": {
            "plan": "standard",
            "status": "active",
            "current_period_end": "2026-05-01T00:00:00Z",
            "auto_renew": false,
            "kwh_included": 10.0,
            "kwh_used": 4.0,
            "kwh_remaining": 6.0
          },
          "key": {
            "name": "subscriber",
            "allowance": null
          }
        }
        """#,
        #"""
        {
          "balance": {
            "credits_remaining_usd": 3.0
          },
          "subscription": null,
          "key": {
            "name": "blocked",
            "allowance": {
              "blocked": true,
              "period": "monthly"
            }
          }
        }
        """#,
        #"""
        {
          "balance": {
            "credits_remaining_usd": 8.0,
            "total_credits_usd": 10.0,
            "credits_used_usd": 2.0,
            "accounting_method": "energy"
          },
          "usage": {
            "lifetime": {},
            "current_month": {}
          },
          "limits": {},
          "subscription": {
            "plan": "standard",
            "status": "active",
            "current_period_start": "2026-04-11T05:05:25.123Z",
            "current_period_end": "2026-05-11T05:05:25.456Z"
          },
          "key": {
            "name": "x",
            "allowance": null
          }
        }
        """#,
        #"""
        {
          "balance": {
            "credits_remaining_usd": 5.0,
            "total_credits_usd": 10.0,
            "credits_used_usd": 5.0,
            "accounting_method": "energy"
          },
          "usage": {
            "lifetime": {},
            "current_month": {}
          },
          "limits": {},
          "subscription": null,
          "key": {
            "name": "k",
            "allowance": null
          }
        }
        """#,
        #"""
        {
          "balance": {
            "credits_remaining_usd": 5.0
          },
          "subscription": null,
          "key": {
            "name": "retry",
            "allowance": null
          }
        }
        """#,
    ]
    @Test(arguments: ProviderPluginTransportTests.engines)
    func `native quota fixtures retain windows balances and identity`(engine: ProviderPluginEngineKind) async throws {
        let balances: [Double] = [32.6774, 4.5, 30, 0, 0, 1, 3, 8, 5, 5]
        let percentages: [Double?] = [13.9023 / 20 * 100, nil, nil, nil, 25, 40, nil, nil, nil, nil]
        let labels: [String?] = [
            "Standard plan",
            "Energy",
            "Energy",
            "Energy",
            "Pro Energy plan",
            "Standard plan",
            nil,
            "Standard plan",
            "Energy",
            nil,
        ]
        for (index, fixture) in Self.fixtures.enumerated() {
            let usage = try await Self.fetch(fixture, engine: engine)
            #expect(usage.providerCost?.used == balances[index])
            #expect(usage.providerCost?.limit == 0)
            #expect(usage.providerCost?.currencyCode == "USD")
            #expect(usage.providerCost?.period == "Neuralwatt prepaid balance")
            #expect(usage.primary?.usedPercent == percentages[index])
            #expect(usage.identity?.loginMethod == labels[index])
            #expect(usage.dataConfidence == .exact)
            #expect(usage.updatedAt == Date(timeIntervalSince1970: 1))
            #expect(usage.providerCost?.updatedAt == usage.updatedAt)
            #expect(usage.secondary == nil)
            #expect(usage.tertiary == nil)
            if index == 0 {
                #expect(usage.primary?.resetDescription == "13.90 / 20 kWh")
                #expect(usage.primary?.windowMinutes == 43200)
                #expect(usage.primary?.resetsAt == usage.subscriptionRenewsAt)
                #expect(usage.extraRateWindows?.first?.title == "Key Monthly")
                #expect(usage.extraRateWindows?.first?.window.usedPercent == 25)
            } else if index == 4 {
                #expect(usage.primary?.resetDescription == "2.50 / 10 kWh")
            } else if index == 5 {
                #expect(usage.primary?.resetsAt != nil)
                #expect(usage.subscriptionRenewsAt == nil)
            } else if index == 6 {
                #expect(usage.extraRateWindows?.first?.window.usedPercent == 100)
            } else {
                #expect(usage.extraRateWindows == nil)
            }
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `fixed decimal kWh and derived totals match native`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(
            #"""
            {"balance":{"total_credits_usd":10,"credits_used_usd":3},
             "subscription":{"kwh_used":1.125,"kwh_remaining":2.675}}
            """#,
            engine: engine)
        #expect(usage.providerCost?.used == 7)
        #expect(usage.primary?.resetDescription == "1.12 / 3.80 kWh")
        let empty = try await Self.fetch(#"{"balance":{"total_credits_usd":10}}"#, engine: engine)
        #expect(empty.primary == nil)
        #expect(empty.providerCost == nil)
        #expect(empty.identity?.loginMethod == nil)
        let zero = try await Self.fetch(
            #"{"balance":{"credits_remaining_usd":-0.0},"subscription":{"kwh_included":10,"kwh_used":-0.0}}"#,
            engine: engine)
        #expect(zero.primary?.resetDescription == "-0 / 10 kWh")
        #expect(zero.providerCost?.used.sign == .minus)
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `quota transport retries once and preserves cancellation`(engine: ProviderPluginEngineKind) async throws {
        let counter = NeuralWattRequestCounter()
        let runtime = try Self.runtime(engine, transport: ProviderHTTPTransportHandler { request in
            if await counter.next() == 1 { throw URLError(.timedOut) }
            return Self.response(request, body: Self.fixtures[0])
        })
        _ = try await runtime.fetchUsage(
            settings: ["BASE_URL": "https://api.neuralwatt.test"],
            secrets: ["NEURALWATT_API_KEY": "fixture-key"])
        #expect(await counter.count == 2)
        for error: any Error in [CancellationError(), URLError(.cancelled)] {
            let cancelled = try Self.runtime(engine, transport: ProviderHTTPTransportHandler { _ in throw error })
            await #expect(throws: CancellationError.self) {
                try await cancelled.fetchUsage(
                    settings: ["BASE_URL": "https://api.neuralwatt.test"],
                    secrets: ["NEURALWATT_API_KEY": "fixture-key"])
            }
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `quota HTTP retry exhaustion is not repeated by the pipeline`(engine: ProviderPluginEngineKind) async throws {
        let counter = NeuralWattRequestCounter()
        let runtime = try Self.runtime(engine, transport: ProviderHTTPTransportHandler { request in
            _ = await counter.next()
            return Self.response(request, body: "unavailable", status: 503)
        })
        do {
            _ = try await ProviderFetchDelayedRetry.run {
                try await runtime.fetchUsage(
                    settings: ["BASE_URL": "https://api.neuralwatt.test"],
                    secrets: ["NEURALWATT_API_KEY": "fixture-key"])
            }
            Issue.record("Expected HTTP failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .apiFailure)
            #expect(error.message == "Neuralwatt API error: HTTP 503")
            #expect(error.retryAfterSeconds == nil)
        }
        #expect(await counter.count == 2)
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `malformed fields remain parse failures`(engine: ProviderPluginEngineKind) async throws {
        for body in [
            "{}",
            "[]",
            "null",
            "not JSON",
            #"{"balance":{}}"#,
            #"{"balance":{"credits_remaining_usd":-1}}"#,
            #"{"balance":{"credits_remaining_usd":"1"}}"#,
            #"{"balance":{"credits_remaining_usd":1},"subscription":{"current_period_end":"2026"}}"#,
            #"{"balance":{"credits_remaining_usd":1},"usage":{"current_month":{"requests":1.2}}}"#,
        ] {
            do {
                _ = try await Self.fetch(body, engine: engine)
                Issue.record("Expected parse failure")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
            }
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `request and authentication diagnostics match native`(engine: ProviderPluginEngineKind) async throws {
        for status in [200, 401, 403, 404] {
            let runtime = try Self.runtime(engine, transport: ProviderHTTPTransportHandler { request in
                #expect(request.httpMethod == "GET")
                #expect(request.url?.absoluteString == "https://api.neuralwatt.test/v1/quota")
                #expect(request.timeoutInterval == 15)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                return Self.response(request, body: Self.fixtures[0], status: status)
            })
            do {
                _ = try await runtime.fetchUsage(
                    settings: ["BASE_URL": "https://api.neuralwatt.test/v1"],
                    secrets: ["NEURALWATT_API_KEY": " fixture-key "])
                #expect(status == 200)
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == ([401, 403].contains(status) ? .missingCredential : .apiFailure))
            }
        }
    }

    @Test(arguments: ProviderPluginTransportTests.engines)
    func `configured quota paths preserve the entire query`(engine: ProviderPluginEngineKind) async throws {
        for (base, expected) in [
            ("https://api.neuralwatt.test", "https://api.neuralwatt.test/v1/quota"),
            ("https://api.neuralwatt.test/v1/", "https://api.neuralwatt.test/v1/quota"),
            ("https://api.neuralwatt.test/prefix?tenant=a?b", "https://api.neuralwatt.test/prefix/v1/quota?tenant=a?b"),
        ] {
            let runtime = try Self.runtime(engine, transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == expected)
                return Self.response(request, body: Self.fixtures[0])
            })
            _ = try await runtime.fetchUsage(
                settings: ["BASE_URL": base], secrets: ["NEURALWATT_API_KEY": "fixture-key"])
        }
    }

    private static func fetch(_ body: String, engine: ProviderPluginEngineKind) async throws -> UsageSnapshot {
        let runtime = try Self.runtime(engine, transport: ProviderHTTPTransportHandler { request in
            Self.response(request, body: body)
        })
        return try await runtime.fetchUsage(
            settings: ["BASE_URL": "https://api.neuralwatt.test"],
            secrets: ["NEURALWATT_API_KEY": "fixture-key"],
            now: Date(timeIntervalSince1970: 1))
    }

    private static func runtime(
        _ engine: ProviderPluginEngineKind,
        transport: any ProviderHTTPTransport) throws -> ProviderPluginRuntime
    {
        let url = try #require(CodexBarCoreResources.bundle?.url(forResource: "neuralwatt", withExtension: "js"))
        return try ProviderPluginRuntime(
            source: String(contentsOf: url, encoding: .utf8),
            transport: transport,
            engine: engine)
    }

    private static func response(_ request: URLRequest, body: String, status: Int = 200) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor NeuralWattRequestCounter {
    private(set) var count = 0
    func next() -> Int { self.count += 1; return self.count }
}
