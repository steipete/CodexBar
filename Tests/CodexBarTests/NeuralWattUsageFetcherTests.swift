import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct NeuralWattUsageFetcherTests {
    @Test
    func `parses quota response into usage snapshot`() throws {
        let body = #"""
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
        """#

        let snapshot = try NeuralWattUsageFetcher._parseSnapshotForTesting(
            Data(body.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.totalCreditsUSD == 52.34)
        #expect(snapshot.creditsUsedUSD == 19.6626)
        let expectedCreditPercent = 19.6626 / 52.34 * 100
        #expect(abs(snapshot.creditUsedPercent - expectedCreditPercent) < 1e-6)
        #expect(snapshot.keyAllowanceUsedPercent == 25.0)
        #expect(snapshot.currentMonthCostUSD == 160.1463)
        let expectedSubscriptionPercent = 13.9023 / 20 * 100
        let primaryPercent = usage.primary?.usedPercent
        #expect(primaryPercent.map { abs($0 - expectedSubscriptionPercent) < 1e-6 } == true)
        #expect(usage.primary?.resetDescription == "13.90 / 20 kWh")
        #expect(usage.primary?.resetsAt == snapshot.subscription?.currentPeriodEnd)
        #expect(usage.subscriptionRenewsAt == snapshot.subscription?.currentPeriodEnd)
        #expect(usage.providerCost?.used == 32.6774)
        #expect(usage.providerCost?.period == "Neuralwatt prepaid balance")
        #expect(usage.loginMethod(for: .neuralwatt) == "Standard plan")
        #expect(usage.extraRateWindows?.count == 1)
        #expect(usage.extraRateWindows?.contains { $0.id == "current-month-spend" } == false)
        let allowanceWindow = usage.extraRateWindows?.first { $0.id == "key-allowance" }
        #expect(allowanceWindow?.title == "Key Monthly")
    }

    @Test
    func `parses response with null subscription using accounting method`() throws {
        let body = #"""
        {
          "snapshot_at": "2026-04-16T18:30:00Z",
          "balance": {
            "credits_remaining_usd": 4.5,
            "total_credits_usd": 5.0,
            "credits_used_usd": 0.5,
            "accounting_method": "energy"
          },
          "usage": {
            "lifetime": {"cost_usd": 0.5, "requests": 10, "tokens": 1000, "energy_kwh": 0.01},
            "current_month": {"cost_usd": 0.5, "requests": 10, "tokens": 1000, "energy_kwh": 0.01}
          },
          "limits": {"overage_limit_usd": null, "rate_limit_tier": "free"},
          "subscription": null,
          "key": {"name": "trial", "allowance": null}
        }
        """#

        let snapshot = try NeuralWattUsageFetcher._parseSnapshotForTesting(
            Data(body.utf8),
            updatedAt: Date(timeIntervalSince1970: 100))
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.creditUsedPercent == 10)
        #expect(snapshot.subscription == nil)
        #expect(snapshot.keyAllowanceUsedPercent == nil)
        #expect(usage.primary == nil)
        #expect(usage.providerCost?.used == 4.5)
        #expect(usage.subscriptionRenewsAt == nil)
        #expect(usage.loginMethod(for: .neuralwatt) == "Energy")
        // No resettable extra quota windows when there is no per-key allowance.
        #expect(usage.extraRateWindows == nil)
    }

    @Test
    func `parses response with missing credits used derived from remaining`() throws {
        let body = #"""
        {
          "balance": {
            "credits_remaining_usd": 30.0,
            "total_credits_usd": 100.0,
            "accounting_method": "energy"
          },
          "usage": {"lifetime": {}, "current_month": {}},
          "limits": {},
          "subscription": null,
          "key": {"name": "x", "allowance": null}
        }
        """#

        let snapshot = try NeuralWattUsageFetcher._parseSnapshotForTesting(
            Data(body.utf8),
            updatedAt: Date(timeIntervalSince1970: 2))
        // credits_used_usd missing but derived as 100 - 30 = 70.
        #expect(snapshot.effectiveUsedCredits == 70)
        #expect(snapshot.creditUsedPercent == 70)
    }

    @Test
    func `keeps known zero prepaid balance separate from subscription quota`() throws {
        let body = #"""
        {
          "balance": {
            "credits_remaining_usd": 0.0,
            "total_credits_usd": 0.0,
            "accounting_method": "energy"
          },
          "usage": {"lifetime": {}, "current_month": {}},
          "limits": {},
          "subscription": null,
          "key": {"name": "x", "allowance": null}
        }
        """#

        let snapshot = try NeuralWattUsageFetcher._parseSnapshotForTesting(
            Data(body.utf8),
            updatedAt: Date(timeIntervalSince1970: 2))
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.effectiveRemainingCredits == 0)
        #expect(snapshot.effectiveTotalCredits == nil)
        #expect(snapshot.creditUsedPercent == 100)
        #expect(usage.primary == nil)
        #expect(usage.providerCost?.used == 0)
        #expect(usage.providerCost?.period == "Neuralwatt prepaid balance")
    }

    @Test
    func `zero prepaid balance does not exhaust active subscription`() throws {
        let body = #"""
        {
          "balance": {
            "credits_remaining_usd": 0.0,
            "total_credits_usd": 0.0,
            "accounting_method": "energy"
          },
          "usage": {"lifetime": {}, "current_month": {}},
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
          "key": {"name": "subscriber", "allowance": null}
        }
        """#

        let usage = try NeuralWattUsageFetcher._parseSnapshotForTesting(
            Data(body.utf8),
            updatedAt: Date(timeIntervalSince1970: 4))
            .toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetDescription == "2.50 / 10 kWh")
        #expect(usage.providerCost?.used == 0)
        #expect(usage.loginMethod(for: .neuralwatt) == "Pro Energy plan")
    }

    @Test
    func `non renewing subscription keeps period end without renewal date`() throws {
        let body = #"""
        {
          "balance": {"credits_remaining_usd": 1.0},
          "subscription": {
            "plan": "standard",
            "status": "active",
            "current_period_end": "2026-05-01T00:00:00Z",
            "auto_renew": false,
            "kwh_included": 10.0,
            "kwh_used": 4.0,
            "kwh_remaining": 6.0
          },
          "key": {"name": "subscriber", "allowance": null}
        }
        """#

        let usage = try NeuralWattUsageFetcher._parseSnapshotForTesting(
            Data(body.utf8),
            updatedAt: Date(timeIntervalSince1970: 6))
            .toUsageSnapshot()

        #expect(usage.primary?.resetsAt != nil)
        #expect(usage.subscriptionRenewsAt == nil)
    }

    @Test
    func `blocked key allowance is exhausted without numeric limit`() throws {
        let body = #"""
        {
          "balance": {"credits_remaining_usd": 3.0},
          "subscription": null,
          "key": {"name": "blocked", "allowance": {"blocked": true, "period": "monthly"}}
        }
        """#

        let usage = try NeuralWattUsageFetcher._parseSnapshotForTesting(
            Data(body.utf8),
            updatedAt: Date(timeIntervalSince1970: 5))
            .toUsageSnapshot()

        #expect(usage.extraRateWindows?.first?.window.usedPercent == 100)
    }

    @Test
    func `parses fractional subscription dates`() throws {
        let body = #"""
        {
          "balance": {
            "credits_remaining_usd": 8.0,
            "total_credits_usd": 10.0,
            "credits_used_usd": 2.0,
            "accounting_method": "energy"
          },
          "usage": {"lifetime": {}, "current_month": {}},
          "limits": {},
          "subscription": {
            "plan": "standard",
            "status": "active",
            "current_period_start": "2026-04-11T05:05:25.123Z",
            "current_period_end": "2026-05-11T05:05:25.456Z"
          },
          "key": {"name": "x", "allowance": null}
        }
        """#

        let snapshot = try NeuralWattUsageFetcher._parseSnapshotForTesting(
            Data(body.utf8),
            updatedAt: Date(timeIntervalSince1970: 3))

        #expect(snapshot.subscription?.currentPeriodEnd != nil)
        #expect(snapshot.creditUsedPercent == 20)
    }

    @Test
    func `rejects malformed successful response without balance`() throws {
        let body = #"{"error":"temporarily unavailable"}"#

        do {
            _ = try NeuralWattUsageFetcher._parseSnapshotForTesting(
                Data(body.utf8),
                updatedAt: Date(timeIntervalSince1970: 4))
            Issue.record("Expected NeuralWattUsageError.parseFailed")
        } catch let error as NeuralWattUsageError {
            guard case let .parseFailed(message) = error else {
                Issue.record("Expected parseFailed, got \(error)")
                return
            }
            #expect(message.contains("balance"))
        }
    }

    @Test
    func `fetch usage rejects blank API key before request`() async throws {
        do {
            _ = try await NeuralWattUsageFetcher.fetchUsage(
                apiKey: "   ",
                environment: [NeuralWattSettingsReader.apiURLEnvironmentKey: "https://api.neuralwatt.test"])
            Issue.record("Expected NeuralWattUsageError.missingCredentials")
        } catch let error as NeuralWattUsageError {
            guard case .missingCredentials = error else {
                Issue.record("Expected missingCredentials, got \(error)")
                return
            }
        }
    }

    @Test
    func `fetch rejects endpoint override before sending API key`() async throws {
        let transport = ProviderHTTPTransportHandler { _ in
            Issue.record("Endpoint override validation must happen before the request")
            throw URLError(.badURL)
        }

        await #expect(throws: NeuralWattSettingsError.invalidEndpointOverride(
            NeuralWattSettingsReader.apiURLEnvironmentKey))
        {
            _ = try await NeuralWattUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                environment: [NeuralWattSettingsReader.apiURLEnvironmentKey: "https://user@example.com"],
                transport: transport)
        }
    }

    @Test
    func `fetch preserves transport cancellation`() async throws {
        let transport = ProviderHTTPTransportHandler { _ in
            throw CancellationError()
        }

        do {
            _ = try await NeuralWattUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                environment: [:],
                transport: transport)
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected: refresh cancellation must not become a provider error.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test
    func `unauthorized fetch throws missing credentials`() async throws {
        let registered = URLProtocol.registerClass(NeuralWattStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(NeuralWattStubURLProtocol.self)
            }
            NeuralWattStubURLProtocol.handler = nil
        }

        NeuralWattStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.makeResponse(url: url, body: #"{"detail":"bad key"}"#, statusCode: 401)
        }

        do {
            _ = try await NeuralWattUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                environment: [NeuralWattSettingsReader.apiURLEnvironmentKey: "https://api.neuralwatt.test"],
                retryPolicy: .disabled)
            Issue.record("Expected NeuralWattUsageError.missingCredentials")
        } catch let error as NeuralWattUsageError {
            guard case .missingCredentials = error else {
                Issue.record("Expected missingCredentials, got \(error)")
                return
            }
        }
    }

    @Test
    func `fetch usage sends bearer authorization header`() async throws {
        let registered = URLProtocol.registerClass(NeuralWattStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(NeuralWattStubURLProtocol.self)
            }
            NeuralWattStubURLProtocol.handler = nil
        }

        NeuralWattStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v1/quota")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
            #expect(request.timeoutInterval == 15)

            let body = #"""
            {
              "balance": {"credits_remaining_usd": 5.0, "total_credits_usd": 10.0,
                          "credits_used_usd": 5.0, "accounting_method": "energy"},
              "usage": {"lifetime": {}, "current_month": {}},
              "limits": {}, "subscription": null, "key": {"name": "k", "allowance": null}
            }
            """#
            return Self.makeResponse(url: url, body: body, statusCode: 200)
        }

        let usage = try await NeuralWattUsageFetcher.fetchUsage(
            apiKey: " sk-test ",
            environment: [NeuralWattSettingsReader.apiURLEnvironmentKey: "https://api.neuralwatt.test"])

        #expect(usage.creditUsedPercent == 50)
    }

    @Test
    func `non success fetch throws generic HTTP error`() async throws {
        let registered = URLProtocol.registerClass(NeuralWattStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(NeuralWattStubURLProtocol.self)
            }
            NeuralWattStubURLProtocol.handler = nil
        }

        NeuralWattStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.makeResponse(url: url, body: #"{"detail":"bad key"}"#, statusCode: 500)
        }

        do {
            _ = try await NeuralWattUsageFetcher.fetchUsage(
                apiKey: "sk-test",
                environment: [NeuralWattSettingsReader.apiURLEnvironmentKey: "https://api.neuralwatt.test"],
                retryPolicy: .disabled)
            Issue.record("Expected NeuralWattUsageError.apiError")
        } catch let error as NeuralWattUsageError {
            guard case let .apiError(message) = error else {
                Issue.record("Expected apiError, got \(error)")
                return
            }
            #expect(message == "HTTP 500")
        }
    }

    @Test
    func `fetch retries transient quota failure`() async throws {
        let body = #"""
        {
          "balance": {"credits_remaining_usd": 5.0},
          "subscription": null,
          "key": {"name": "retry", "allowance": null}
        }
        """#
        let transport = NeuralWattSequenceTransport(statusCodes: [503, 200], body: Data(body.utf8))
        let retryPolicy = ProviderHTTPRetryPolicy(maxRetries: 1, baseDelaySeconds: 0, maxDelaySeconds: 0)

        let usage = try await NeuralWattUsageFetcher.fetchUsage(
            apiKey: "sk-test",
            environment: [NeuralWattSettingsReader.apiURLEnvironmentKey: "https://api.neuralwatt.test"],
            transport: transport,
            retryPolicy: retryPolicy)

        #expect(usage.effectiveRemainingCredits == 5)
        #expect(await transport.requestCount == 2)
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }
}

private actor NeuralWattSequenceTransport: ProviderHTTPTransport {
    private var statusCodes: [Int]
    private let body: Data
    private(set) var requestCount = 0

    init(statusCodes: [Int], body: Data) {
        self.statusCodes = statusCodes
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requestCount += 1
        let statusCode = self.statusCodes.isEmpty ? 200 : self.statusCodes.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (self.body, response)
    }
}

final class NeuralWattStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.neuralwatt.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
