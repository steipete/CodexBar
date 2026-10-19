import Foundation
import Testing
@testable import CodexBarCore

struct CodexProviderDescriptorTests {
    @Test
    func `usage dashboard resolves the Codex usage overview tab`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let dashboardURL = try #require(metadata.dashboardURL)
        let url = try #require(URL(string: dashboardURL))
        #expect(url.absoluteString == "https://chatgpt.com/settings/usage?tab=overview")
        #expect(url.query == "tab=overview")
    }
}
