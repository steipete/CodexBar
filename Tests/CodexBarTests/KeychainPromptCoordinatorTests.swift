import Testing
@testable import CodexBar

struct KeychainPromptCoordinatorTests {
    @Test
    func `detects raw SwiftPM debug executable`() {
        #expect(KeychainPromptCoordinator.isUnbundledCodexBarExecutable(
            "/Users/me/CodexBar/.build/arm64-apple-macosx/debug/CodexBar"))
        #expect(KeychainPromptCoordinator.isUnbundledCodexBarExecutable(
            "/Users/me/CodexBar/.build/debug/CodexBar"))
    }

    @Test
    func `detects raw SwiftPM release executable`() {
        #expect(KeychainPromptCoordinator.isUnbundledCodexBarExecutable(
            "/Users/me/CodexBar/.build/arm64-apple-macosx/release/CodexBar"))
    }

    @Test
    func `detects custom SwiftPM scratch path`() {
        #expect(KeychainPromptCoordinator.isUnbundledCodexBarExecutable(
            "/tmp/codexbar-build/arm64-apple-macosx/debug/CodexBar"))
    }

    @Test
    func `keeps packaged app keychain behavior`() {
        #expect(!KeychainPromptCoordinator.isUnbundledCodexBarExecutable(
            "/Applications/CodexBar.app/Contents/MacOS/CodexBar"))
        #expect(!KeychainPromptCoordinator.isUnbundledCodexBarExecutable(
            "/Users/me/CodexBar/.build/package/CodexBar.app/Contents/MacOS/CodexBar"))
    }

    @Test
    func `ignores unrelated executable paths`() {
        #expect(!KeychainPromptCoordinator.isUnbundledCodexBarExecutable(
            "/Users/me/CodexBar/.build/debug/CodexBarCLI"))
        #expect(!KeychainPromptCoordinator.isUnbundledCodexBarExecutable(""))
        #expect(!KeychainPromptCoordinator.isUnbundledCodexBarExecutable("CodexBar"))
    }
}
