import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Testing
@testable import CodexBarCore

struct AntigravityPricingRefreshTests {
    private typealias Fixture = AntigravityLocalFixture
    private static let catalog = Data(#"""
    {"google":{"id":"google","models":{"gemini-fixture-priced":{
    "id":"gemini-fixture-priced","cost":{"input":1,"output":2,"cache_read":0.2}}}},
    "anthropic":{"id":"anthropic","models":{"claude-fixture":{
    "id":"claude-fixture","cost":{"input":1,"output":2}}}},
    "openai":{"id":"openai","models":{"gpt-fixture":{
    "id":"gpt-fixture","cost":{"input":1,"output":2}}}}}
    """#.utf8)

    @Test(arguments: ["absent", "empty", "known", "unknown"])
    func `routine local reads do not wait for pricing and empty history starts no download`(
        scenario: String) async throws
    {
        let fixture = try Fixture()
        if scenario != "absent" {
            let blobs = scenario == "empty" ? [] : [Fixture.blob(
                model: scenario == "known" ? "claude-sonnet-4-6" : "gemini-fixture-priced")]
            try fixture.database(blobs: blobs)
        }
        let gate = AntigravityPricingGate()
        let task = Task {
            let snapshot = try await Self.fetch(
                fixture,
                client: ModelsDevClient(transport: AntigravityPricingTransport {
                    await gate.startAndWait()
                }))
            await gate.markReturned()
            return snapshot
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await !gate.returned, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let returnedBeforeDownload = await gate.returned
        await gate.release()
        let snapshot = try await task.value
        #expect(returnedBeforeDownload)
        if scenario == "absent" || scenario == "empty" {
            #expect(await gate.requestCount == 0)
            #expect(snapshot.daily.isEmpty)
        } else {
            #expect(snapshot.last30DaysTokens == 198)
            #expect((snapshot.last30DaysCostUSD != nil) == (scenario == "known"))
            // Drain the detached refresh before its fixture directory is removed.
            let drainDeadline = clock.now.advanced(by: .seconds(2))
            while ModelsDevPricingPipeline.lookup(
                providerID: "google",
                modelID: "gemini-fixture-priced",
                now: Fixture.now,
                cacheRoot: fixture.root.appendingPathComponent("scanner-cache")) == nil,
                clock.now < drainDeadline
            {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await gate.requestCount == 1)
            #expect(ModelsDevPricingPipeline.lookup(
                providerID: "google",
                modelID: "gemini-fixture-priced",
                now: Fixture.now,
                cacheRoot: fixture.root.appendingPathComponent("scanner-cache")) != nil)
        }
    }

    @Test
    func `explicit refresh can price an unknown local model`() async throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(model: "gemini-fixture-priced")])
        let snapshot = try await Self.fetch(
            fixture, force: true, client: ModelsDevClient(transport: AntigravityPricingTransport {}))
        #expect(snapshot.last30DaysTokens == 198)
        #expect(snapshot.last30DaysCostUSD == 111e-6 + 50 * 0.2e-6 + 37 * 2e-6)
    }

    @Test
    func `pricing rescan cannot replace a complete first scan with a smaller partial subtotal`() async throws {
        let fixture = try Fixture()
        let databaseURL = try fixture.database(blobs: [
            Fixture.blob(model: "gemini-fixture-priced"),
            Fixture.blob(model: "gemini-fixture-priced", seconds: 1_787_832_001),
        ])
        let snapshot = try await Self.fetch(
            fixture,
            force: true,
            client: ModelsDevClient(transport: AntigravityPricingTransport {
                let database = try Fixture.open(databaseURL)
                defer { sqlite3_close(database) }
                try Fixture.execute(database, "DELETE FROM gen_metadata WHERE idx = 1")
                try Fixture.insert(database, row: 1, blob: [0x08, 0xFF])
            }))
        #expect(snapshot.last30DaysTokens == 396)
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(!snapshot.historyScanIsPartial)
    }

    @Test
    func `offline pricing retains unpriced local usage`() async throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(model: "gemini-fixture-priced")])
        let snapshot = try await Self.fetch(
            fixture,
            force: true,
            client: ModelsDevClient(transport: AntigravityPricingTransport {
                throw URLError(.notConnectedToInternet)
            }))
        #expect(snapshot.last30DaysTokens == 198)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.historyCoverageIsEstablished)
    }

    private static func fetch(
        _ fixture: Fixture,
        force: Bool = false,
        client: ModelsDevClient) async throws -> CostUsageTokenSnapshot
    {
        var options = CostUsageScanner.Options()
        options.calendar = Fixture.calendar
        options.cacheRoot = fixture.root.appendingPathComponent("scanner-cache")
        return try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: fixture.environment,
            now: Fixture.now,
            forceRefresh: force,
            allowPricingRefresh: true,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: client)
    }

    private struct AntigravityPricingTransport: ModelsDevHTTPTransport {
        let beforeResponse: @Sendable () async throws -> Void

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await self.beforeResponse()
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (AntigravityPricingRefreshTests.catalog, response)
        }
    }
}

private actor AntigravityPricingGate {
    private(set) var returned = false
    private(set) var requestCount = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func startAndWait() async {
        self.requestCount += 1
        guard !self.released else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func markReturned() { self.returned = true }

    func release() {
        self.released = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
