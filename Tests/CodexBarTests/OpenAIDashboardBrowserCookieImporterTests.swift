import CodexBarCore
import Testing

struct OpenAIDashboardBrowserCookieImporterTests {
    @Test
    func `mismatch error mentions source label`() {
        let err = OpenAIDashboardBrowserCookieImporter.ImportError.noMatchingAccount(
            found: [
                .init(sourceLabel: "Safari", email: "a@example.com"),
                .init(sourceLabel: "Chrome", email: "b@example.com"),
            ])
        let msg = err.localizedDescription
        #expect(msg.contains("Safari=a@example.com"))
        #expect(msg.contains("Chrome=b@example.com"))
    }

    @Test @MainActor
    func `normalize workspace label trims and lowercases`() {
        let importer = OpenAIDashboardBrowserCookieImporter(browserDetection: BrowserDetection(cacheTTL: 0))
        #expect(importer._normalizeWorkspaceLabelForTesting("  Team Workspace  ") == "team workspace")
        #expect(importer._normalizeWorkspaceLabelForTesting(nil) == nil)
    }
}
