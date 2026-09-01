import Foundation
import Testing
@testable import CodexBarCore

struct MuseDashboardURLResolverTests {
    @Test
    func `canonicalizes only the tenant-scoped usage route`() throws {
        let url = try #require(MuseDashboardURLResolver.canonicalUsageURL(
            "https://dev.meta.ai/usage?project_id=project-1&team_id=team_2&secret=discard-me"))

        #expect(url.absoluteString == "https://dev.meta.ai/usage/?team_id=team_2&project_id=project-1")
        #expect(MuseDashboardURLResolver.canonicalUsageURL(
            "https://example.com/usage/?team_id=team&project_id=project") == nil)
        #expect(MuseDashboardURLResolver.canonicalUsageURL(
            "https://dev.meta.ai/usage/?team_id=team") == nil)
    }
}
