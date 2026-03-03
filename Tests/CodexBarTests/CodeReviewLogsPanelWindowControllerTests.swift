import Testing
@testable import CodexBar

@Suite
struct CodeReviewLogsPanelWindowControllerTests {
    @Test
    func acceptsChatGPTCodeReviewURL() {
        let url = CodeReviewLogsPanelWindowController
            .sanitizedLogURL("https://chatgpt.com/codex?tab=code_reviews")
        #expect(url?.absoluteString == "https://chatgpt.com/codex?tab=code_reviews")
    }

    @Test
    func resolvesRelativeChatGPTCodeReviewURL() {
        let url = CodeReviewLogsPanelWindowController.sanitizedLogURL("/codex?tab=code_reviews")
        #expect(url?.absoluteString == "https://chatgpt.com/codex?tab=code_reviews")
    }

    @Test
    func acceptsChatGPTSubdomainCodeReviewURL() {
        let url = CodeReviewLogsPanelWindowController
            .sanitizedLogURL("https://platform.chatgpt.com/codex?tab=code_reviews")
        #expect(url?.absoluteString == "https://platform.chatgpt.com/codex?tab=code_reviews")
    }

    @Test
    func acceptsGitHubReviewURLs() {
        let url = CodeReviewLogsPanelWindowController
            .sanitizedLogURL("https://github.com/org/repo/pull/123")
        #expect(url?.absoluteString == "https://github.com/org/repo/pull/123")
    }

    @Test
    func acceptsGitHubCommitAndCompareURLs() {
        let commitURL = CodeReviewLogsPanelWindowController
            .sanitizedLogURL("https://github.com/org/repo/commit/abc123")
        let compareURL = CodeReviewLogsPanelWindowController
            .sanitizedLogURL("https://github.com/org/repo/compare/main...feature")
        #expect(commitURL?.absoluteString == "https://github.com/org/repo/commit/abc123")
        #expect(compareURL?.absoluteString == "https://github.com/org/repo/compare/main...feature")
    }

    @Test
    func handlesWWWPrefix() {
        let url = CodeReviewLogsPanelWindowController.sanitizedLogURL("https://www.chatgpt.com/codex")
        #expect(url?.absoluteString == "https://www.chatgpt.com/codex")
    }

    @Test
    func rejectsEmptyAndWhitespaceInput() {
        #expect(CodeReviewLogsPanelWindowController.sanitizedLogURL(nil) == nil)
        #expect(CodeReviewLogsPanelWindowController.sanitizedLogURL("") == nil)
        #expect(CodeReviewLogsPanelWindowController.sanitizedLogURL("   \n\t ") == nil)
    }

    @Test
    func rejectsNonReviewGitHubURLs() {
        let url = CodeReviewLogsPanelWindowController.sanitizedLogURL("https://github.com/org/repo")
        #expect(url == nil)
    }

    @Test
    func rejectsUnsupportedSchemesAndHosts() {
        let javascriptURL = CodeReviewLogsPanelWindowController.sanitizedLogURL("javascript:alert(1)")
        let externalURL = CodeReviewLogsPanelWindowController.sanitizedLogURL("https://example.com/review/1")
        let spoofedChatGPTURL = CodeReviewLogsPanelWindowController.sanitizedLogURL("https://evil-chatgpt.com/codex")
        #expect(javascriptURL == nil)
        #expect(externalURL == nil)
        #expect(spoofedChatGPTURL == nil)
    }
}
