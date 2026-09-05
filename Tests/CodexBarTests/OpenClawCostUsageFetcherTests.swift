import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct OpenClawCostUsageFetcherTests {
    @Test
    func `gateway request uses the caller range and timezone`() throws {
        let arguments = try OpenClawCostUsageFetcher.arguments(
            now: Self.now, historyDays: 2, calendar: Self.calendar)
        #expect(Array(arguments.prefix(3)) == ["gateway", "call", "usage.cost"])
        let index = try #require(arguments.firstIndex(of: "--params"))
        let data = try #require(arguments[index + 1].data(using: .utf8))
        let params = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(params == [
            "agentScope": "all", "endDate": "2026-09-04", "mode": "specific",
            "startDate": "2026-09-03", "timeZone": "Asia/Shanghai",
        ])
        #expect(Array(arguments.suffix(3)) == ["--timeout", "20000", "--json"])
    }

    @Test
    func `gateway totals map without inventing model data or partial cost`() throws {
        let report = try OpenClawCostUsageFetcher.parseDailyReport(Self.summaryJSON(daily: [
            Self.dayJSON(date: "2026-09-04", input: 10, output: 2, total: 12, cost: 0.02, missing: 1),
            Self.dayJSON(date: "2026-09-03", input: 20, output: 4, cacheRead: 6, total: 30, cost: 0.04),
        ]))

        #expect(report.data.map(\.date) == ["2026-09-03", "2026-09-04"])
        #expect(report.data[0].cacheReadTokens == 6)
        #expect(report.data[0].costUSD == 0.04)
        #expect(report.data[0].modelBreakdowns == nil)
        #expect(report.data[1].totalTokens == 12)
        #expect(report.data[1].costUSD == nil)
        #expect(report.data[1].requestCount == nil)
        #expect(report.data[1].pricedRequestCount == nil)
        #expect(report.data[1].unpricedRequestCount == nil)
        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: report, now: Self.now, historyDays: 2, calendar: Self.calendar)
        #expect(snapshot.last30DaysCostUSD == nil)
    }

    @Test(arguments: ["partial", "stale", "refreshing"])
    func `incomplete caches fail closed`(status: String) {
        #expect(throws: OpenClawUsageError.incompleteCache(status)) {
            try OpenClawCostUsageFetcher.parseDailyReport(Self.summaryJSON(daily: [], cacheStatus: status))
        }
    }

    @Test(arguments: [
        Self.summaryJSON(daily: [Self.dayJSON(date: "2026-02-30")]),
        Self.summaryJSON(daily: [Self.dayJSON(date: "2026-09-04"), Self.dayJSON(date: "2026-09-04")]),
        Self.summaryJSON(daily: [Self.dayJSON(date: "2026-09-04", input: -1)]),
        #"{"daily":[{"date":"2026-09-04","input":1}]}"#,
        "not-json",
    ])
    func `invalid summaries fail closed`(output: String) {
        #expect(throws: OpenClawUsageError.invalidResponse) {
            try OpenClawCostUsageFetcher.parseDailyReport(output)
        }
    }

    @Test
    func `overflowing aggregate costs fail closed`() {
        let huge = Double.greatestFiniteMagnitude
        let output = Self.summaryJSON(daily: [
            Self.dayJSON(date: "2026-09-03", cost: huge),
            Self.dayJSON(date: "2026-09-04", cost: huge),
        ])
        #expect(throws: OpenClawUsageError.invalidResponse) {
            try OpenClawCostUsageFetcher.parseDailyReport(output)
        }
    }

    @Test
    func `token snapshot consumes only official gateway JSON`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("openclaw")
        try Self.writeFakeCLI(at: binary, output: Self.summaryJSON(daily: [
            Self.dayJSON(date: "2026-09-03", input: 20, output: 4, total: 24, cost: 0.04),
            Self.dayJSON(date: "2026-09-04", input: 10, output: 2, total: 12, cost: 0.02),
        ]))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .openclaw,
            environment: ["OPENCLAW_CLI_PATH": binary.path, "PATH": "/usr/bin:/bin"],
            now: Self.now,
            historyDays: 2,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: Self.scannerOptions)
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.sessionTokens == 12)
        #expect(snapshot.last30DaysTokens == 36)
        #expect(snapshot.last30DaysCostUSD == 0.06)
        #expect(snapshot.costProvenance == .listPriceEstimate)
    }

    @Test
    func `provider advertises aggregate gateway cost support`() {
        let descriptor = OpenClawProviderDescriptor.descriptor
        #expect(descriptor.id == .openclaw)
        #expect(descriptor.tokenCost.supportsTokenSnapshot)
        #expect(!descriptor.tokenCost.showsRequestHistory)
        #expect(descriptor.cli.binaryLocator != nil)
        #expect(descriptor.cli.prefersBinaryLocatorForWhich)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private static var now: Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 9, day: 4, hour: 12))!
    }

    private static var scannerOptions: CostUsageScanner.Options {
        var options = CostUsageScanner.Options()
        options.calendar = Self.calendar
        return options
    }

    private static func summaryJSON(daily: [String], cacheStatus: String = "fresh") -> String {
        #"{"daily":[\#(daily.joined(separator: ","))],"cacheStatus":{"status":"\#(cacheStatus)"}}"#
    }

    private static func dayJSON(
        date: String,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        total: Int = 0,
        cost: Double = 0,
        missing: Int = 0) -> String
    {
        """
        {"date":"\(date)","input":\(input),"output":\(output),"cacheRead":\(cacheRead),
        "cacheWrite":0,"totalTokens":\(total),"totalCost":\(cost),"missingCostEntries":\(missing)}
        """
    }

    private static func writeFakeCLI(at url: URL, output: String) throws {
        try "#!/bin/sh\nprintf '%s' '\(output)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
