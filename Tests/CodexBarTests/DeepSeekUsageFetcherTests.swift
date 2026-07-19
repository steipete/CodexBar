import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekUsageFetcherTests {
    private struct TimeoutError: Error {}

    private actor SummaryCancellationProbe {
        private var started = false
        private var cancelled = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var cancelledWaiters: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            self.started = true
            for waiter in self.startedWaiters {
                waiter.resume()
            }
            self.startedWaiters.removeAll()
        }

        func waitUntilStarted() async {
            if self.started { return }
            await withCheckedContinuation { continuation in
                self.startedWaiters.append(continuation)
            }
        }

        func markCancelled() {
            self.cancelled = true
            for waiter in self.cancelledWaiters {
                waiter.resume()
            }
            self.cancelledWaiters.removeAll()
        }

        func waitUntilCancelled() async {
            if self.cancelled { return }
            await withCheckedContinuation { continuation in
                self.cancelledWaiters.append(continuation)
            }
        }

        func wasCancelled() -> Bool {
            self.cancelled
        }
    }

    private actor ConcurrentFetchGate {
        private var arrivalCount = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func arriveAndWait() async {
            self.arrivalCount += 1
            if self.arrivalCount == 2 {
                for waiter in self.waiters {
                    waiter.resume()
                }
                self.waiters.removeAll()
                return
            }

            await withCheckedContinuation { continuation in
                self.waiters.append(continuation)
            }
        }
    }

    private actor SummaryCallCounter {
        private(set) var value = 0

        func increment() {
            self.value += 1
        }
    }

    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError()
            }

            let result = try await group.next()
            group.cancelAll()
            guard let result else { throw TimeoutError() }
            return result
        }
    }

    private static func waitForCancellation(_ probe: SummaryCancellationProbe) async -> Bool {
        for _ in 0..<100 {
            if await probe.wasCancelled() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await probe.wasCancelled()
    }

    private static let sampleBalanceJSON = """
    {
      "is_available": true,
      "balance_infos": [
        {
          "currency": "USD",
          "total_balance": "50.00",
          "granted_balance": "10.00",
          "topped_up_balance": "40.00"
        }
      ]
    }
    """

    private static func sampleSummary(updatedAt: Date = Date()) -> DeepSeekUsageSummary {
        DeepSeekUsageSummary(
            todayTokens: 123,
            currentMonthTokens: 456,
            todayCost: 1.23,
            currentMonthCost: 4.56,
            requestCount: 7,
            currentMonthRequestCount: 8,
            topModel: "deepseek-v4-flash",
            categoryBreakdown: [
                DeepSeekCategoryBreakdown(category: .promptCacheHitToken, tokens: 123, cost: 1.23),
            ],
            daily: [],
            currency: "USD",
            updatedAt: updatedAt)
    }

    @Test
    func `parses USD balance response`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "50.00",
              "granted_balance": "10.00",
              "topped_up_balance": "40.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.isAvailable == true)
        #expect(snapshot.currency == "USD")
        #expect(snapshot.totalBalance == 50.0)
        #expect(snapshot.grantedBalance == 10.0)
        #expect(snapshot.toppedUpBalance == 40.0)
    }

    @Test
    func `parses paid and granted balances from Platform session summary`() throws {
        let json = """
        {
          "code": 0,
          "data": {
            "biz_code": 0,
            "biz_data": {
              "normal_wallets": [
                {"balance": "7.97", "currency": "USD"}
              ],
              "bonus_wallets": [
                {"balance": 0.50, "currency": "USD"}
              ]
            }
          }
        }
        """

        let snapshot = try DeepSeekUsageFetcher._parsePlatformBalanceForTesting(Data(json.utf8))

        #expect(snapshot.hasBalance)
        #expect(snapshot.isAvailable)
        #expect(snapshot.currency == "USD")
        #expect(abs(snapshot.totalBalance - 8.47) < 0.000_001)
        #expect(snapshot.toppedUpBalance == 7.97)
        #expect(snapshot.grantedBalance == 0.50)
    }

    @Test
    func `Platform session summary rejects malformed balance`() {
        let json = """
        {
          "code": 0,
          "data": {
            "biz_code": 0,
            "biz_data": {
              "normal_wallets": [{"balance": "not-a-number", "currency": "USD"}],
              "bonus_wallets": []
            }
          }
        }
        """

        #expect(throws: DeepSeekUsageError.self) {
            try DeepSeekUsageFetcher._parsePlatformBalanceForTesting(Data(json.utf8))
        }
    }

    @Test
    func `Platform session summary maps top level auth envelopes before decoding data`() {
        let json = """
        {
          "code": 40003,
          "data": "unexpected"
        }
        """

        #expect {
            try DeepSeekUsageFetcher._parsePlatformBalanceForTesting(Data(json.utf8))
        } throws: { error in
            error as? DeepSeekUsageError == .invalidPlatformToken
        }
    }

    @Test
    func `Platform session summary maps nested auth envelopes before decoding wallets`() {
        let json = """
        {
          "code": 0,
          "data": {
            "biz_code": 40002,
            "biz_data": "unexpected"
          }
        }
        """

        #expect {
            try DeepSeekUsageFetcher._parsePlatformBalanceForTesting(Data(json.utf8))
        } throws: { error in
            error as? DeepSeekUsageError == .invalidPlatformToken
        }
    }

    @Test
    func `parses CNY balance response`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "110.00",
              "granted_balance": "10.00",
              "topped_up_balance": "100.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.currency == "CNY")
        #expect(snapshot.totalBalance == 110.0)
        #expect(snapshot.toppedUpBalance == 100.0)
    }

    @Test
    func `prefers USD when both currencies present`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "100.00",
              "granted_balance": "0.00",
              "topped_up_balance": "100.00"
            },
            {
              "currency": "USD",
              "total_balance": "20.00",
              "granted_balance": "5.00",
              "topped_up_balance": "15.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.currency == "USD")
        #expect(snapshot.totalBalance == 20.0)
    }

    @Test
    func `prefers positive CNY balance over empty USD balance`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "0.00",
              "granted_balance": "0.00",
              "topped_up_balance": "0.00"
            },
            {
              "currency": "CNY",
              "total_balance": "100.00",
              "granted_balance": "0.00",
              "topped_up_balance": "100.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.currency == "CNY")
        #expect(snapshot.totalBalance == 100.0)
        #expect(usage.primary?.resetDescription?.contains("¥100.00") == true)
    }

    @Test
    func `zero balance prompts top up even when unavailable`() throws {
        let json = """
        {
          "is_available": false,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "0.00",
              "granted_balance": "0.00",
              "topped_up_balance": "0.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.isAvailable == false)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "$0.00 — add credits at platform.deepseek.com")
        #expect(usage.identity?.loginMethod == nil)
    }

    @Test
    func `full bar when balance available`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "5.00",
              "granted_balance": "0.00",
              "topped_up_balance": "5.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetDescription?.contains("$5.00") == true)
        #expect(usage.identity?.loginMethod == nil)
    }

    @Test
    func `throws on malformed balance string`() {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "not-a-number",
              "granted_balance": "0.00",
              "topped_up_balance": "0.00"
            }
          ]
        }
        """
        #expect {
            _ = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        } throws: { error in
            guard case DeepSeekUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `empty balance_infos returns unavailable snapshot`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": []
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        #expect(snapshot.isAvailable == false)
        #expect(snapshot.totalBalance == 0.0)
    }

    @Test
    func `throws on invalid JSON root`() {
        let json = "[{ \"is_available\": true }]"
        #expect {
            _ = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        } throws: { error in
            guard case DeepSeekUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `balance description includes paid and granted breakdown`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "50.00",
              "granted_balance": "10.00",
              "topped_up_balance": "40.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()
        let detail = usage.primary?.resetDescription ?? ""
        #expect(detail.contains("$50.00"))
        #expect(detail.contains("$40.00"))
        #expect(detail.contains("$10.00"))
    }

    @Test
    func `CNY balance uses yen symbol`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "100.00",
              "granted_balance": "0.00",
              "topped_up_balance": "100.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()
        let detail = usage.primary?.resetDescription ?? ""
        #expect(detail.contains("¥"))
    }

    @Test
    func `balance snapshot has nil usage summary`() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "50.00",
              "granted_balance": "10.00",
              "topped_up_balance": "40.00"
            }
          ]
        }
        """
        let snapshot = try DeepSeekUsageFetcher._parseSnapshotForTesting(Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.deepseekUsage == nil)
    }

    @Test
    func `usage amount and cost fetch concurrently`() async throws {
        let gate = ConcurrentFetchGate()
        let payloads = try await Self.withTimeout(.seconds(1)) {
            try await DeepSeekUsageFetcher._fetchUsagePayloadsForTesting(
                fetchAmount: {
                    await gate.arriveAndWait()
                    return Data("amount".utf8)
                },
                fetchCost: {
                    await gate.arriveAndWait()
                    return Data("cost".utf8)
                })
        }

        #expect(String(bytes: payloads.amount, encoding: .utf8) == "amount")
        #expect(String(bytes: payloads.cost, encoding: .utf8) == "cost")
    }

    @Test
    func `balance returns promptly when optional usage summary is slow`() async throws {
        let probe = SummaryCancellationProbe()
        let snapshot = try await Self.withTimeout(.seconds(10)) {
            try await DeepSeekUsageFetcher._fetchUsageForTesting(
                apiKey: "test-key",
                platformToken: "platform-token",
                includeOptionalUsage: true,
                optionalSummaryJoinGrace: .milliseconds(50),
                fetchBalanceData: { _ in
                    Data(Self.sampleBalanceJSON.utf8)
                },
                fetchSummary: { _ in
                    await probe.markStarted()
                    do {
                        try await Task.sleep(for: .seconds(60))
                        return Self.sampleSummary()
                    } catch is CancellationError {
                        await probe.markCancelled()
                        throw CancellationError()
                    }
                })
        }

        #expect(snapshot.totalBalance == 50.0)
        #expect(snapshot.usageSummary == nil)
        #expect(await Self.waitForCancellation(probe))
    }

    @Test
    func `balance grace does not wait for optional summary that ignores cancellation`() async throws {
        let startedAt = ContinuousClock.now
        let snapshot = try await DeepSeekUsageFetcher._fetchUsageForTesting(
            apiKey: "test-key",
            platformToken: "platform-token",
            includeOptionalUsage: true,
            optionalSummaryJoinGrace: .milliseconds(20),
            fetchBalanceData: { _ in
                Data(Self.sampleBalanceJSON.utf8)
            },
            fetchSummary: { _ in
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        continuation.resume(returning: Self.sampleSummary())
                    }
                }
            })
        let elapsed = startedAt.duration(to: .now)

        #expect(snapshot.totalBalance == 50.0)
        #expect(snapshot.usageSummary == nil)
        #expect(elapsed < .milliseconds(300), "Optional summary delayed balance: \(elapsed)")

        // Let the deliberately cancellation-ignoring test task drain before the test exits.
        try await Task.sleep(for: .milliseconds(550))
    }

    @Test
    func `balance returns when optional usage summary fails closed`() async throws {
        let snapshot = try await DeepSeekUsageFetcher._fetchUsageForTesting(
            apiKey: "test-key",
            platformToken: "platform-token",
            includeOptionalUsage: true,
            optionalSummaryJoinGrace: .seconds(2),
            fetchBalanceData: { _ in
                Data(Self.sampleBalanceJSON.utf8)
            },
            fetchSummary: { _ in
                throw DeepSeekUsageError.networkError("simulated failure")
            })

        #expect(snapshot.totalBalance == 50.0)
        #expect(snapshot.usageSummary == nil)
    }

    @Test
    func `Platform balance returns when optional usage summary fails`() async throws {
        let snapshot = try await DeepSeekUsageFetcher._fetchPlatformUsageForTesting(
            includeOptionalUsage: true,
            optionalSummaryJoinGrace: .seconds(2),
            fetchBalance: {
                DeepSeekUsageSnapshot(
                    isAvailable: true,
                    currency: "USD",
                    totalBalance: 8.06,
                    grantedBalance: 0,
                    toppedUpBalance: 8.06,
                    updatedAt: Date())
            },
            fetchSummary: {
                throw DeepSeekUsageError.networkError("simulated failure")
            })

        #expect(snapshot.totalBalance == 8.06)
        #expect(snapshot.usageSummary == nil)
        #expect(snapshot.detailedUsageState == .unavailable)
    }

    @Test
    func `Platform balance skips detailed endpoints when optional usage is disabled`() async throws {
        let counter = SummaryCallCounter()
        let snapshot = try await DeepSeekUsageFetcher._fetchPlatformUsageForTesting(
            includeOptionalUsage: false,
            fetchBalance: {
                DeepSeekUsageSnapshot(
                    isAvailable: true,
                    currency: "USD",
                    totalBalance: 8.06,
                    grantedBalance: 0,
                    toppedUpBalance: 8.06,
                    updatedAt: Date())
            },
            fetchSummary: {
                await counter.increment()
                return Self.sampleSummary()
            })

        #expect(snapshot.totalBalance == 8.06)
        #expect(snapshot.usageSummary == nil)
        #expect(snapshot.detailedUsageState == .notRequested)
        #expect(await counter.value == 0)
    }

    @Test
    func `cancels optional usage summary when balance fetch fails`() async throws {
        let probe = SummaryCancellationProbe()

        do {
            _ = try await DeepSeekUsageFetcher._fetchUsageForTesting(
                apiKey: "test-key",
                platformToken: "platform-token",
                includeOptionalUsage: true,
                optionalSummaryJoinGrace: .seconds(2),
                fetchBalanceData: { _ in
                    await probe.waitUntilStarted()
                    throw DeepSeekUsageError.networkError("simulated balance failure")
                },
                fetchSummary: { _ in
                    await probe.markStarted()
                    do {
                        try await Task.sleep(for: .seconds(1))
                        return Self.sampleSummary()
                    } catch is CancellationError {
                        await probe.markCancelled()
                        throw DeepSeekUsageError.networkError("cancelled")
                    }
                })
            Issue.record("Expected balance failure")
        } catch DeepSeekUsageError.networkError {
            #expect(await Self.waitForCancellation(probe))
        }
    }

    @Test
    func `cancels optional usage summary when balance parsing fails`() async throws {
        let probe = SummaryCancellationProbe()

        do {
            _ = try await DeepSeekUsageFetcher._fetchUsageForTesting(
                apiKey: "test-key",
                platformToken: "platform-token",
                includeOptionalUsage: true,
                optionalSummaryJoinGrace: .seconds(2),
                fetchBalanceData: { _ in
                    await probe.waitUntilStarted()
                    return Data("{\"is_available\":true,\"balance_infos\":[".utf8)
                },
                fetchSummary: { _ in
                    await probe.markStarted()
                    do {
                        try await Task.sleep(for: .seconds(1))
                        return Self.sampleSummary()
                    } catch is CancellationError {
                        await probe.markCancelled()
                        throw DeepSeekUsageError.networkError("cancelled")
                    }
                })
            Issue.record("Expected balance parse failure")
        } catch DeepSeekUsageError.parseFailed {
            #expect(await Self.waitForCancellation(probe))
        }
    }

    @Test
    func `parent cancellation propagates while waiting for optional usage summary`() async throws {
        let probe = SummaryCancellationProbe()
        let task = Task {
            try await DeepSeekUsageFetcher._fetchUsageForTesting(
                apiKey: "test-key",
                platformToken: "platform-token",
                includeOptionalUsage: true,
                optionalSummaryJoinGrace: .seconds(30),
                fetchBalanceData: { _ in
                    Data(Self.sampleBalanceJSON.utf8)
                },
                fetchSummary: { _ in
                    await probe.markStarted()
                    do {
                        try await Task.sleep(for: .seconds(60))
                        return Self.sampleSummary()
                    } catch is CancellationError {
                        await probe.markCancelled()
                        throw CancellationError()
                    }
                })
        }

        await probe.waitUntilStarted()
        task.cancel()

        do {
            _ = try await Self.withTimeout(.seconds(10)) {
                try await task.value
            }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(await Self.waitForCancellation(probe))
        }
    }

    @Test
    func `parent cancellation stops summary while balance transport ignores cancellation`() async throws {
        let balanceStarted = AsyncStream<Void>.makeStream(of: Void.self)
        let probe = SummaryCancellationProbe()
        let task = Task {
            try await DeepSeekUsageFetcher._fetchUsageForTesting(
                apiKey: "test-key",
                platformToken: "platform-token",
                includeOptionalUsage: true,
                optionalSummaryJoinGrace: .seconds(30),
                fetchBalanceData: { _ in
                    balanceStarted.continuation.yield(())
                    return await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                            continuation.resume(returning: Data(Self.sampleBalanceJSON.utf8))
                        }
                    }
                },
                fetchSummary: { _ in
                    await probe.markStarted()
                    do {
                        try await Task.sleep(for: .seconds(60))
                        return Self.sampleSummary()
                    } catch is CancellationError {
                        await probe.markCancelled()
                        throw CancellationError()
                    }
                })
        }

        var balanceIterator = balanceStarted.stream.makeAsyncIterator()
        _ = await balanceIterator.next()
        await probe.waitUntilStarted()
        let cancellationStartedAt = ContinuousClock.now
        task.cancel()

        await probe.waitUntilCancelled()
        #expect(cancellationStartedAt.duration(to: .now) < .milliseconds(300))
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func `usage period defaults to Gregorian API calendar`() throws {
        let date = try #require(Self.utcDate(year: 2026, month: 5, day: 26))
        let period = try DeepSeekUsageFetcher._apiUsagePeriodForTesting(now: date)

        #expect(period.month == 5)
        #expect(period.year == 2026)
    }

    @Test
    func `usage period supports injected test calendar`() throws {
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let date = try #require(Self.utcDate(year: 2026, month: 5, day: 26))
        let period = try DeepSeekUsageFetcher._apiUsagePeriodForTesting(now: date, calendar: calendar)

        #expect(period.month == 5)
        #expect(period.year == 2569)
    }

    @Test
    func `production path can populate usage summary when optional fetch succeeds`() async throws {
        let expected = Self.sampleSummary()
        let snapshot = try await DeepSeekUsageFetcher._fetchUsageForTesting(
            apiKey: "test-key",
            platformToken: "platform-token",
            includeOptionalUsage: true,
            optionalSummaryJoinGrace: .seconds(2),
            fetchBalanceData: { _ in
                Data(Self.sampleBalanceJSON.utf8)
            },
            fetchSummary: { _ in
                expected
            })

        #expect(snapshot.totalBalance == 50.0)
        #expect(snapshot.usageSummary == expected)
        #expect(snapshot.detailedUsageState == .available)
    }

    @Test
    func `API key alone reports that a web session is required`() async throws {
        let summaryCalls = SummaryCallCounter()
        let snapshot = try await DeepSeekUsageFetcher._fetchUsageForTesting(
            apiKey: "test-key",
            platformToken: nil,
            includeOptionalUsage: true,
            optionalSummaryJoinGrace: .seconds(1),
            fetchBalanceData: { _ in
                Data(Self.sampleBalanceJSON.utf8)
            },
            fetchSummary: { _ in
                await summaryCalls.increment()
                return Self.sampleSummary()
            })

        #expect(snapshot.totalBalance == 50.0)
        #expect(snapshot.usageSummary == nil)
        #expect(snapshot.detailedUsageState == .webSessionRequired)
        #expect(await summaryCalls.value == 0)
    }

    @Test
    func `platform token is separate from the balance API key`() async throws {
        let snapshot = try await DeepSeekUsageFetcher._fetchUsageForTesting(
            apiKey: "balance-api-key",
            platformToken: "browser-user-token",
            includeOptionalUsage: true,
            optionalSummaryJoinGrace: .seconds(1),
            fetchBalanceData: { key in
                #expect(key == "balance-api-key")
                return Data(Self.sampleBalanceJSON.utf8)
            },
            fetchSummary: { token in
                #expect(token == "browser-user-token")
                return Self.sampleSummary()
            })

        #expect(snapshot.usageSummary != nil)
        #expect(snapshot.detailedUsageState == .available)
    }

    @Test
    func `invalid platform token preserves balance and requests sign in`() async throws {
        let snapshot = try await DeepSeekUsageFetcher._fetchUsageForTesting(
            apiKey: "balance-api-key",
            platformToken: "expired-browser-token",
            includeOptionalUsage: true,
            optionalSummaryJoinGrace: .seconds(1),
            fetchBalanceData: { _ in
                Data(Self.sampleBalanceJSON.utf8)
            },
            fetchSummary: { _ in
                throw DeepSeekUsageError.invalidPlatformToken
            })

        #expect(snapshot.totalBalance == 50.0)
        #expect(snapshot.usageSummary == nil)
        #expect(snapshot.detailedUsageState == .webSessionRequired)
    }

    private static func utcDate(year: Int, month: Int, day: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
