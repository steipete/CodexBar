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
        let client = ModelsDevClient(transport: AntigravityPricingTransport {
            await gate.startAndWait()
        })
        let task = Task { try await Self.fetch(fixture, client: client) }
        // The transport stays blocked until the local read completes. This join is only a
        // deadlock watchdog; it releases the fixture even if the foreground path regresses.
        let outcome = await BoundedTaskJoin(sourceTask: task).value(joinGrace: .seconds(60))
        await gate.release()
        let snapshot = try await task.value
        guard case .value = outcome else {
            Issue.record("Local read did not complete while the pricing transport was blocked")
            return
        }
        if scenario == "absent" || scenario == "empty" {
            #expect(await gate.requestCount == 0)
            #expect(snapshot.daily.isEmpty)
        } else {
            #expect(snapshot.last30DaysTokens == 187)
            #expect((snapshot.last30DaysCostUSD != nil) == (scenario == "known"))
            let started = Task<Bool, Error> { await gate.waitUntilStarted() }
            let startOutcome = await BoundedTaskJoin(sourceTask: started).value(joinGrace: .seconds(60))
            guard case .value(true) = startOutcome else {
                Issue.record("Local usage did not start its background pricing refresh")
                return
            }
            // Join the already-started refresh before removing its cache directory.
            await ModelsDevPricingPipeline.refreshIfNeeded(
                now: Fixture.now,
                cacheRoot: fixture.root.appendingPathComponent("scanner-cache"),
                client: client)
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
        #expect(snapshot.last30DaysTokens == 187)
        let expected = 100e-6 + 50 * 0.2e-6 + 37 * 2e-6
        #expect(abs((snapshot.last30DaysCostUSD ?? .nan) - expected) < 1e-9)
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
        #expect(snapshot.last30DaysTokens == 374)
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
        #expect(snapshot.last30DaysTokens == 187)
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
    private(set) var requestCount = 0
    private let started = AsyncStream<Void>.makeStream()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func startAndWait() async {
        self.requestCount += 1
        self.started.continuation.yield(())
        self.started.continuation.finish()
        guard !self.released else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func waitUntilStarted() async -> Bool {
        for await _ in self.started.stream {
            return true
        }
        return false
    }

    func release() {
        self.released = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
