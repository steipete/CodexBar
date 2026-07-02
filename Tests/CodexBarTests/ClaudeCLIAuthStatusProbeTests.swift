import Testing
@testable import CodexBarCore

struct ClaudeCLIAuthStatusProbeTests {
    @Test
    func `parses logged in status`() {
        #expect(ClaudeCLIAuthStatusProbe.parseLoggedIn(#"{"loggedIn":true,"authMethod":"claude.ai"}"#))
    }

    @Test
    func `rejects logged out and malformed status`() {
        #expect(!ClaudeCLIAuthStatusProbe.parseLoggedIn(#"{"loggedIn":false,"authMethod":"none"}"#))
        #expect(!ClaudeCLIAuthStatusProbe.parseLoggedIn("not-json"))
        #expect(!ClaudeCLIAuthStatusProbe.parseLoggedIn(#"{"authMethod":"none"}"#))
    }
}
