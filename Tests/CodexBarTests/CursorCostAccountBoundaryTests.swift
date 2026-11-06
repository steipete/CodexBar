import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct CursorCostAccountBoundaryTests {
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
#endif
