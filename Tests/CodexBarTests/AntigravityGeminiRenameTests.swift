import Foundation
import Testing
@testable import CodexBarCore

/// Google renamed the Antigravity desktop app to "Gemini.app" with bundle ID
/// `com.google.GeminiMacOS` (#2836). These tests cover the renamed-app
/// detection surfaces alongside the legacy Antigravity identifiers.
struct AntigravityGeminiRenameTests {
    @Test
    func `language server under renamed gemini app path classifies as app`() {
        let gemini = "/applications/gemini.app/contents/resources/bin/language_server --csrf_token abc"
        #expect(AntigravityStatusProbe.antigravityProcessKind(gemini) == .app)
    }

    @Test
    func `gemini desktop main binary does not classify as language server`() {
        #expect(
            AntigravityStatusProbe.antigravityProcessKind(
                "/Applications/Gemini.app/Contents/MacOS/Gemini") == nil)
    }

    @Test
    func `unrelated gemini cli process does not classify`() {
        #expect(
            AntigravityStatusProbe.antigravityProcessKind(
                "node /usr/local/lib/node_modules/@google/gemini-cli/dist/index.js") == nil)
    }

    @Test
    func `language server under lookalike app name does not classify`() {
        #expect(
            AntigravityStatusProbe.antigravityProcessKind(
                "/applications/notgemini.app/contents/resources/bin/language_server --csrf_token abc") == nil)
    }
}
