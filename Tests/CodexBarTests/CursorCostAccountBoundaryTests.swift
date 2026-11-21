import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct CursorCostAccountBoundaryTests {
    @Test
    func `a rejected nonblank manual cost credential cannot publish ambient local history`() async throws {
        // The shared production transport deliberately permits URLProtocol stubs in test processes.
        try #require(TestProcessSafety.isRunning)
        let registered = URLProtocol.registerClass(CursorCostManual401Protocol.self)
        try #require(registered)
        defer { URLProtocol.unregisterClass(CursorCostManual401Protocol.self) }
        CursorCostManual401Protocol.resetCount()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-cost-401-boundary-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent(".config/tokscale/cursor-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let csvURL = cache.appendingPathComponent("usage-ambient-account.csv")
        try """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost,Cost to you
        2026-08-20T10:00:00.000Z,synthetic-model,1200,800,400,300,1500,42,0
        """.write(to: csvURL, atomically: true, encoding: .utf8)
        try Self.writeOwnedJSON(to: cache)
        #expect(CursorLocalCSVReader.parseFile(at: csvURL).first?.cost == 42)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        await CursorLocalCSVReader.$cacheHomeForTesting.withValue(root) {
            #expect(CursorLocalCSVReader.cachedCSVPaths().map { $0.resolvingSymlinksInPath() } ==
                [csvURL.resolvingSymlinksInPath()])
            do {
                _ = try await CostUsageFetcher.loadTokenSnapshot(
                    provider: .cursor,
                    environment: [:],
                    now: Date(timeIntervalSince1970: 1_787_227_200),
                    historyDays: 30,
                    cursorCookieHeaderOverride: CursorCostManual401Protocol.cookieHeader,
                    allowPricingRefresh: false,
                    includePiSessions: false,
                    scannerOptions: .init(calendar: calendar))
                Issue.record("Rejected selected credentials must fail instead of returning ambient CSV spend")
            } catch CursorStatusProbeError.notLoggedIn {
                // Preserve the exact selected source's HTTP 401 error through the outer cost loader.
            } catch {
                Issue.record("Expected selected-source notLoggedIn, received \(error)")
            }
        }
        #expect(CursorCostManual401Protocol.requestCount > 0)
    }

    @Test(arguments: ["", " \t\n "])
    func `explicitly blank manual cost credentials cannot publish ambient local history`(
        manualHeader: String) async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-cost-boundary-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent(".config/tokscale/cursor-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let csvURL = cache.appendingPathComponent("usage-ambient-account.csv")
        try """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost,Cost to you
        2026-08-20T10:00:00.000Z,synthetic-model,1200,800,400,300,1500,42,0
        """.write(to: csvURL, atomically: true, encoding: .utf8)
        try Self.writeOwnedJSON(to: cache)
        let rows = CursorLocalCSVReader.parseFile(at: csvURL)
        #expect(rows.count == 1)
        #expect(rows.first?.cost == 42)

        // An explicit blank override is rejected before app auth, session cache, browser import,
        // or transport. Its error must also survive the outer cost loader's local fallback.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        await CursorLocalCSVReader.$cacheHomeForTesting.withValue(root) {
            #expect(CursorLocalCSVReader.cachedCSVPaths().map { $0.resolvingSymlinksInPath() } ==
                [csvURL.resolvingSymlinksInPath()])
            do {
                let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
                    provider: .cursor,
                    environment: [:],
                    now: Date(timeIntervalSince1970: 1_787_227_200),
                    historyDays: 30,
                    cursorCookieHeaderOverride: manualHeader,
                    allowPricingRefresh: false,
                    includePiSessions: false,
                    scannerOptions: .init(calendar: calendar))
                Issue.record("Missing selected credentials must fail, not publish unowned local history")
                #expect(snapshot.last30DaysCostUSD != 42)
            } catch CursorStatusProbeError.noSessionCookie {
                // The selected source remains authoritative even when local history is available.
            } catch {
                Issue.record("Expected noSessionCookie, received \(error)")
            }
        }
    }

    @Test(arguments: [false, true])
    func `automatic cost fallback uses canonical JSON without counting CSV migration copies`(
        partial: Bool) async throws
    {
        let cache = try CursorJSONTestFixtures.Cache()
        defer { cache.remove() }
        try Self.writeCSV(to: cache.directory)
        var rows: [Any] = [CursorJSONTestFixtures.event()]
        if partial { rows.append(42) }
        try cache.write(CursorJSONTestFixtures.document(rows))
        try cache.write(
            CursorJSONTestFixtures.document([CursorJSONTestFixtures.event(input: 9000)]),
            name: "usage.account-foreign.json")
        let snapshot = try await Self.automaticSnapshot(in: cache)
        #expect(snapshot.last30DaysTokens == 135)
        #expect(snapshot.last30DaysCostUSD == 0.125)
        #expect(snapshot.meteredCostUSD == (partial ? nil : 0))
        #expect(snapshot.historyScanIsPartial == partial)
        #expect(snapshot.historyCoverageIsEstablished == !partial)
        #expect(snapshot.credentialScopeFingerprint == nil)
        #expect(CursorCostManual401Protocol.requestCount == 1)
    }

    @Test(arguments: ["metadata", "malformed", "empty", "stale"])
    func `unavailable canonical JSON cannot borrow CSV history`(state: String) async throws {
        let cache = try CursorJSONTestFixtures.Cache()
        defer { cache.remove() }
        try Self.writeCSV(to: cache.directory)
        var document = CursorJSONTestFixtures.document([CursorJSONTestFixtures.event()])
        switch state {
        case "metadata": document["_tokscale"] = ["version": 1, "accountId": "another-account"]
        case "empty": document["usageEventsDisplay"] = []
        case "stale":
            document = CursorJSONTestFixtures.document([
                CursorJSONTestFixtures.event(timestamp: "2025-11-13T10:00:00Z"),
            ])
        default: break
        }
        try cache.write(document)
        if state == "malformed" {
            try Data("{".utf8).write(to: cache.directory.appendingPathComponent("usage.json"))
        }
        do {
            _ = try await Self.automaticSnapshot(in: cache)
            Issue.record("Unavailable canonical cache must not publish the CSV's unrelated spend")
        } catch CursorStatusProbeError.notLoggedIn {
        } catch {
            Issue.record("Expected the original synthetic authentication error, received \(error)")
        }
    }

    @Test
    func `automatic fallback retains CSV only history without reading inactive JSON accounts`() async throws {
        let cache = try CursorJSONTestFixtures.Cache()
        defer { cache.remove() }
        try Self.writeCSV(to: cache.directory)
        try cache.write(
            CursorJSONTestFixtures.document([CursorJSONTestFixtures.event()]),
            name: "usage.account-foreign.json")
        let snapshot = try await Self.automaticSnapshot(in: cache)
        #expect(snapshot.last30DaysCostUSD == 42)
        #expect(snapshot.meteredCostUSD == nil)
    }

    private static func writeOwnedJSON(to cache: URL) throws {
        let document = CursorJSONTestFixtures.document([
            CursorJSONTestFixtures.event(timestamp: "2026-08-20T10:00:00Z"),
        ])
        try JSONSerialization.data(withJSONObject: document).write(to: cache.appendingPathComponent("usage.json"))
    }

    private static func writeCSV(to cache: URL) throws {
        try """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        2026-11-13T10:00:00Z,synthetic-model,105,100,10,20,135,42
        """.write(to: cache.appendingPathComponent("usage.csv"), atomically: true, encoding: .utf8)
    }

    private static func automaticSnapshot(in cache: CursorJSONTestFixtures
        .Cache) async throws -> CostUsageTokenSnapshot
    {
        try #require(TestProcessSafety.isRunning)
        let registered = URLProtocol.registerClass(CursorCostManual401Protocol.self)
        try #require(registered)
        defer { URLProtocol.unregisterClass(CursorCostManual401Protocol.self) }
        CursorCostManual401Protocol.resetCount()
        return try await KeychainCacheStore.withServiceOverrideForTesting("cursor-json-boundary-\(UUID())") {
            try await KeychainCacheStore.withImplicitTestStoreForTesting {
                try await CookieHeaderCache
                    .withLegacyBaseURLOverrideForTesting(cache.home.appendingPathComponent("legacy")) {
                        try #require(CookieHeaderCache.storeResult(
                            provider: .cursor,
                            cookieHeader: CursorCostManual401Protocol.cookieHeader,
                            sourceLabel: "Synthetic selected browser",
                            authenticationFailurePolicy: .stopFallback))
                        defer { CookieHeaderCache.clear(provider: .cursor) }
                        // The pinned synthetic browser skips app-auth discovery and stops before browser imports.
                        return try await CursorLocalCSVReader.$cacheHomeForTesting.withValue(cache.home) {
                            try await CostUsageFetcher.loadTokenSnapshot(
                                provider: .cursor,
                                environment: [:],
                                now: CursorJSONTestFixtures.now,
                                historyDays: 30,
                                allowPricingRefresh: false,
                                includePiSessions: false,
                                scannerOptions: .init(calendar: CursorJSONTestFixtures.calendar))
                        }
                    }
            }
        }
    }
}

/// Intercept only this test's unique synthetic credential. Reject endpoint drift locally so a
/// changed production request cannot send this credential onto the network.
private final class CursorCostManual401Protocol: URLProtocol {
    static let cookieHeader = "WorkosCursorSessionToken=cursor-cost-boundary-\(UUID().uuidString)"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0

    static var requestCount: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.count
    }

    static func resetCount() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.count = 0
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: "Cookie") == self.cookieHeader
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        Self.lock.unlock()
        guard let url = self.request.url,
              url.scheme == "https", url.host == "cursor.com",
              url.path == "/api/dashboard/get-filtered-usage-events", self.request.httpMethod == "POST",
              let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)
        else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data())
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
