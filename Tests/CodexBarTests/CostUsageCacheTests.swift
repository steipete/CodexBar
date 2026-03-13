import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CostUsageCacheTests {
    @Test
    func cacheFileURL_usesCodexSpecificArtifactVersion() {
        let root = URL(fileURLWithPath: "/tmp/codexbar-cost-cache", isDirectory: true)

        let codexURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: root)
        let claudeURL = CostUsageCacheIO.cacheFileURL(provider: .claude, cacheRoot: root)

        #expect(codexURL.lastPathComponent == "codex-v2.json")
        #expect(claudeURL.lastPathComponent == "claude-v1.json")
    }
}
