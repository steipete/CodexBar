import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIServeWebUITests {
    private var html: String {
        String(decoding: CLIServeWebUI.response().body, as: UTF8.self)
    }

    @Test
    func `web ui renders per account sections for multi account providers`() {
        let html = self.html
        // Multi-account rendering replaces ambient windows and falls back to the
        // slot label when identity is redacted away entirely.
        #expect(html.contains("function renderAccount(account)"))
        #expect(html.contains("account.identity?.accountEmail || account.label"))
        #expect(html.contains("provider.accountsError"))
    }

    @Test
    func `web ui keeps ambient windows when no accounts are present`() {
        let html = self.html
        #expect(html.contains("Array.isArray(provider.accounts)"))
        #expect(html.contains("renderWindow(window)"))
    }

    @Test
    func `serve identity flag decodes like the dashboard command`() {
        #expect(CodexBarCLI.decodeDashboardIdentityMode(
            from: ParsedValues(positional: [], options: [:], flags: [])) == .redacted)
        #expect(CodexBarCLI.decodeDashboardIdentityMode(
            from: ParsedValues(positional: [], options: ["identity": ["full"]], flags: [])) == .full)
        #expect(CodexBarCLI.decodeDashboardIdentityMode(
            from: ParsedValues(positional: [], options: ["identity": ["nope"]], flags: [])) == nil)
    }
}
