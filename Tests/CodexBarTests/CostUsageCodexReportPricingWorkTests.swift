import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCodexReportPricingWorkTests {
    @Test(arguments: [1, 16])
    func `report pricing work scales with models rather than rows or files`(fileCount: Int) throws {
        let fixture = try Self.fixture(fileCount: fileCount, rowsPerFile: 256)
        let catalog = ModelsDevCatalog(providers: [:])
        for operation in ["daily", "projects", "sessions"] {
            let work = CostUsagePricing.CodexPricingWorkRecorder()
            CostUsagePricing.$codexPricingWorkRecorder.withValue(work) {
                switch operation {
                case "daily":
                    let report = CostUsageScanner.buildCodexReportFromCache(
                        cache: fixture.cache, range: fixture.range, modelsDevCatalog: catalog)
                    #expect(report.summary?.totalTokens == fileCount * 256 * 13)
                    #expect(report.summary?.totalCostUSD != nil)
                case "projects":
                    let projects = CostUsageScanner.buildCodexProjectBreakdownsFromCache(
                        cache: fixture.cache, range: fixture.range, modelsDevCatalog: catalog)
                    #expect(projects.count == 1)
                    #expect(projects.first?.totalTokens == fileCount * 256 * 13)
                default:
                    let sessions = CostUsageScanner.buildCodexSessionBreakdownsFromCache(
                        cache: fixture.cache, range: fixture.range, modelsDevCatalog: catalog)
                    #expect(sessions.count == fileCount)
                    #expect(sessions.allSatisfy { $0.totalTokens == 256 * 13 })
                }
            }
            #expect(work.catalogLookups == 1, "\(operation): unchanged model must resolve once per collection")
        }
    }

    static func fixture(fileCount: Int, rowsPerFile: Int) throws
        -> (cache: CostUsageCache, range: CostUsageScanner.CostUsageDayRange)
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12)))
        let range = CostUsageScanner.CostUsageDayRange(since: now, until: now, calendar: calendar)
        let day = range.sinceKey
        let model = "gpt-5.4"
        var cache = CostUsageCache()
        for index in 0..<fileCount {
            let rows = (0..<rowsPerFile).map { (event: Int) in
                CostUsageScanner.CodexUsageRow(
                    day: day,
                    model: model,
                    turnID: "turn-\(index)-\(event)",
                    eventIndex: event,
                    input: 10,
                    cached: 2,
                    output: 3,
                    pricingModel: model,
                    pricingMode: "standard")
            }
            let usage = CostUsageScanner.makeFileUsage(
                mtimeUnixMs: Int64(now.timeIntervalSince1970 * 1000),
                size: 1,
                days: [day: [model: [rowsPerFile * 10, rowsPerFile * 2, rowsPerFile * 3]]],
                parsedBytes: 1,
                sessionId: "session-\(index)",
                projectPath: "/synthetic/project",
                canonicalProjectPath: "/synthetic/project",
                codexStandardTokens: [day: [model: rowsPerFile * 13]],
                codexRows: rows,
                codexScanComplete: true)
            cache.files["/synthetic/session-\(index).jsonl"] = usage
            CostUsageScanner.applyFileDays(cache: &cache, fileDays: usage.days, sign: 1)
        }
        return (cache, range)
    }
}
