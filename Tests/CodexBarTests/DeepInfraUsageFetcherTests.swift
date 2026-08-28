import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct DeepInfraUsageFetcherTests {
    @Test
    func `converts monthly cents and deducts recent usage from prepaid balance`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try DeepInfraUsageFetcher._parseSnapshotForTesting(
            checklistData: Self.checklistData(
                stripeBalance: -99.75,
                recent: 3.94,
                limit: 20),
            usageData: Self.usageData(totalCostCents: 394),
            now: now)

        #expect(abs(snapshot.availableBalanceUSD - 95.81) < 0.000_001)
        #expect(snapshot.amountOwedUSD == 0)
        #expect(abs(snapshot.currentMonthCostUSD - 3.94) < 0.000_001)
        #expect(snapshot.recentCostUSD == 3.94)
        #expect(snapshot.spendingLimitUSD == 20)
        #expect(snapshot.updatedAt == now)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.remainingPercent == 100)
        #expect(usage.primary?.resetDescription == "$95.81 available · $3.94 spent this month")
        #expect(usage.providerCost?.used == 3.94)
        #expect(usage.providerCost?.limit == 20)
        #expect(usage.providerCost?.period == "Billing cycle")
        #expect(usage.identity?.providerID == .deepinfra)
        #expect(usage.dataConfidence == .exact)
    }

    @Test
    func `positive Stripe balance is reported as amount owed`() throws {
        let snapshot = try DeepInfraUsageFetcher._parseSnapshotForTesting(
            checklistData: Self.checklistData(
                stripeBalance: 2.75,
                recent: 7,
                limit: -1),
            usageData: Self.usageData(totalCostCents: 650))

        #expect(snapshot.availableBalanceUSD == 0)
        #expect(snapshot.amountOwedUSD == 9.75)
        #expect(snapshot.spendingLimitUSD == nil)
        #expect(snapshot.toUsageSnapshot().primary?.remainingPercent == 0)
        #expect(snapshot.toUsageSnapshot().primary?.resetDescription == "$9.75 owed · $6.50 spent this month")
        #expect(snapshot.toUsageSnapshot().providerCost == nil)
    }

    @Test
    func `suspended account is marked exhausted`() throws {
        let snapshot = try DeepInfraUsageFetcher._parseSnapshotForTesting(
            checklistData: Self.checklistData(
                stripeBalance: -5,
                recent: 1,
                limit: nil,
                suspended: true,
                suspendReason: "Payment review"),
            usageData: Self.usageData(totalCostCents: 100))
            .toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.primary?.resetDescription?.hasPrefix("Suspended: Payment review") == true)
    }

    @Test
    func `fetches checklist then current usage with bearer token`() async throws {
        let recorder = RequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let path = request.url?.path
            let data = if path == "/payment/checklist" {
                Self.checklistData(stripeBalance: -9, recent: 2, limit: 10)
            } else {
                Self.usageData(totalCostCents: 150)
            }
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (data, response)
        }

        let snapshot = try await DeepInfraUsageFetcher._fetchUsageForTesting(
            apiKey: "fixture-token",
            transport: transport)
        let requests = await recorder.values

        #expect(snapshot.availableBalanceUSD == 7)
        #expect(requests.map(\.url?.path) == ["/payment/checklist", "/payment/usage"])
        #expect(requests.allSatisfy { $0.url?.scheme == "https" })
        #expect(requests.allSatisfy { $0.url?.host == "api.deepinfra.com" })
        #expect(requests[0].url?.query == "compute_owed=true")
        #expect(requests[1].url?.query == "from=current")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" })
        #expect(requests.allSatisfy { $0.timeoutInterval == 30 })
    }

    @Test
    func `surfaces rejected API key as provider error`() async {
        let transport = ProviderHTTPTransportHandler { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(), response)
        }

        await #expect {
            _ = try await DeepInfraUsageFetcher._fetchUsageForTesting(
                apiKey: "rejected-token",
                transport: transport)
        } throws: { error in
            guard case let DeepInfraUsageError.apiError(message) = error else { return false }
            return message.contains("401")
        }
    }

    @Test
    func `rejects malformed billing response`() {
        #expect {
            _ = try DeepInfraUsageFetcher._parseSnapshotForTesting(
                checklistData: Data("{}".utf8),
                usageData: Self.usageData(totalCostCents: 100))
        } throws: { error in
            guard case DeepInfraUsageError.parseFailed = error else { return false }
            return true
        }
    }

    private static func checklistData(
        stripeBalance: Double,
        recent: Double,
        limit: Double?,
        suspended: Bool = false,
        suspendReason: String? = nil) -> Data
    {
        let limitJSON = limit.map { Swift.String($0) } ?? "null"
        let reasonJSON = suspendReason.map { "\"\($0)\"" } ?? "null"
        return Data(
            """
            {
              "stripe_balance": \(stripeBalance),
              "recent": \(recent),
              "limit": \(limitJSON),
              "suspended": \(suspended),
              "suspend_reason": \(reasonJSON)
            }
            """.utf8)
    }

    private static func usageData(totalCostCents: Double) -> Data {
        Data(
            """
            {
              "months": [
                {
                  "period": "2026.07",
                  "items": [],
                  "total_cost": \(totalCostCents)
                }
              ],
              "initial_month": "2026.07"
            }
            """.utf8)
    }
}

private actor RequestRecorder {
    private(set) var values: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.values.append(request)
    }
}
