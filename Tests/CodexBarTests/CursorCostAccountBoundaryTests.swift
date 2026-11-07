import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct CursorCostAccountBoundaryTests {
    @Test
    func `a rejected nonblank manual cost credential cannot publish ambient CSV history`() async throws {
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
    func `explicitly blank manual cost credentials cannot publish ambient CSV history`(
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
