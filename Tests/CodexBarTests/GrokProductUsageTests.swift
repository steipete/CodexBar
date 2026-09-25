import Foundation
import Testing
@testable import CodexBarCore

struct GrokProductUsageTests {
    @Test
    func `billing product shares reach the shared detail section`() throws {
        let billing = try GrokCreditsProxyFetcher.parseSnapshot(Data("""
        {"config":{"creditUsagePercent":6,"productUsage":[
          {"product":"GrokBuild","usagePercent":2},
          {"product":"GrokChat","usagePercent":4}
        ]}}
        """.utf8))
        let usage = GrokUsageSnapshot(
            billing: nil,
            webBilling: billing,
            credentials: nil,
            localSummary: nil,
            cliVersion: nil,
            updatedAt: Date()).toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 6)
        #expect(usage.secondary == nil)
        let section = try #require(usage.details.first)
        #expect(section.title == "Usage breakdown")
        #expect(section.rows.map(\.label) == ["Grok Chat", "Grok Build"])
        #expect(section.rows.map(\.value) == ["4%", "2%"])
    }
}
