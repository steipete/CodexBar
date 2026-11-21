import Foundation
import Testing
@testable import CodexBarCore

struct ProviderLockPathTests {
    @Test
    func `provider locks use application support without creating files`() throws {
        let root = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("CodexBar", isDirectory: true)
        let claude = ClaudeOAuthPendingCacheClearUserDefaultsStore(
            domain: "ProviderLockPathTests.\(UUID().uuidString)", key: "pending")
        let antigravity = AntigravityFileCLISessionLaunchLock()

        #expect(claude.lockURL == root.appendingPathComponent("claude-oauth-cache.lock"))
        #expect(antigravity.fileURL == root.appendingPathComponent("antigravity/agy-session.lock"))
    }
}
