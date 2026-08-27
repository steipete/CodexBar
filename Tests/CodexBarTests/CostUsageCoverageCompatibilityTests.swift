import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCoverageCompatibilityTests {
    @Test(arguments: [false, true])
    func `optional priced counts survive report and retained cache coding`(hasExplicitCount: Bool) throws {
        let count = hasExplicitCount ? #", "pricedRequestCount":1"# : ""
        let json = """
        {"type":"daily","data":[{"date":"2026-08-01","requestCount":3,"costUSD":1,
        "estimatedRequestCount":1,"unpricedRequestCount":1\(count)}]}
        """
        let report = try JSONDecoder().decode(CostUsageDailyReport.self, from: Data(json.utf8))
        #expect(report.data.first?.pricedRequestCount == (hasExplicitCount ? 1 : nil))
        #expect(report.data.first?.coverageCounts == CostUsageCoverageCounts(priced: 1, unpriced: 1, estimated: 1))
        let retained = try #require(CostUsageCodexPreviousReport(
            report: report, cache: CostUsageCache(), reportSinceKey: "2026-08-01", reportUntilKey: "2026-08-01"))
        let payload = try JSONEncoder().encode(retained)
        let restored = try JSONDecoder().decode(CostUsageCodexPreviousReport.self, from: payload)
        #expect(restored.report.data == report.data)
        if !hasExplicitCount {
            let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let rows = try #require(object["data"] as? [[String: Any]])
            #expect(rows.first?["pricedRequestCount"] == nil)
        }
    }

    @Test(arguments: ["c6c46a376ba16304", "55f640e6bb0ccba4"])
    func `reviewed predecessors retain actual previous report payloads without rebuilding`(hash: String) async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let predecessor = CostUsageStore(
            cacheRoot: env.cacheRoot,
            schemaVersion: CostUsageStore.combinedSchemaVersion(
                base: CostUsageStore.baseSchemaVersion,
                parserHash: hash),
            parserHash: hash)
        // Old producer JSON deliberately omits the new optional field.
        let json = """
        {"data":[{"date":"2026-08-01","totalTokens":100,"requestCount":1,"costUSD":12}],
         "updatedAtUnixMs":1000,"scanSinceKey":"2026-08-01","scanUntilKey":"2026-08-01",
         "timeZoneIdentifier":"GMT","roots":{"/synthetic/root":1}}
        """
        let payload = Data(json.utf8)
        var metadata = await predecessor.fetchMetadata()
        metadata.previousReportPayload = payload
        #expect(await predecessor.setMetadata(metadata))
        let current = CostUsageStore(cacheRoot: env.cacheRoot)
        let adopted = await current.fetchMetadata()
        #expect(adopted.previousReportPayload == payload)
        #expect(await current.rebuildCount == 0)
        let retained = try JSONDecoder().decode(
            CostUsageCodexPreviousReport.self, from: #require(adopted.previousReportPayload))
        #expect(retained.report.data.first?.pricedRequestCount == nil)
        #expect(retained.report.data.first?.coverageCounts.priced == 1)
        #expect(retained.report.data.first?.costUSD == 12)
        #expect(retained.matches(
            scanSinceKey: "2026-08-01",
            scanUntilKey: "2026-08-01",
            timeZoneIdentifier: "GMT",
            roots: ["/synthetic/root": 1]))
    }
}
