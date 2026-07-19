import Testing
@testable import CodexBarCore

struct GeminiSourceLabelTests {
    @Test
    func `Gemini source label reflects OAuth backed API requests`() {
        #expect(GeminiStatusFetchStrategy.sourceLabel == "oauth-api")
    }
}
