import Foundation
import Testing
@testable import CodexBarCore

struct VertexAIUsageFetcherTests {
    @Test
    func `usage without limit name matches the regional named limit`() throws {
        let response = try VertexAIUsageFetcher.parseQuotaUsage(
            usageData: Self.fixture("issue-2958-usage-without-limit-name"),
            limitData: Self.fixture("issue-2958-regional-and-global-limits"))

        #expect(response.requestsUsedPercent == 1)
    }

    @Test
    func `existing exact limit name match remains authoritative`() throws {
        let response = try VertexAIUsageFetcher.parseQuotaUsage(
            usageData: Self.fixture("exact-named-usage"),
            limitData: Self.fixture("exact-named-limits"))

        #expect(response.requestsUsedPercent == 25)
    }

    @Test
    func `unnamed usage does not guess between limits in the same region`() throws {
        #expect(throws: VertexAIFetchError.self) {
            try VertexAIUsageFetcher.parseQuotaUsage(
                usageData: Self.fixture("issue-2958-usage-without-limit-name"),
                limitData: Self.fixture("ambiguous-regional-limits"))
        }
    }

    private static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Providers/VertexAI")))
    }
}
