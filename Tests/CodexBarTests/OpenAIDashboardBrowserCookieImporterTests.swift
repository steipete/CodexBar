import Foundation
import Testing
@testable import CodexBarCore

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

    @Test
    func `timed out persistent validation keeps verified session`() {
        #expect(OpenAIDashboardBrowserCookieImporter.shouldTrustVerifiedSession(
            afterPersistFailure: URLError(.timedOut)))
    }

    @Test
    func `non-timeout persistent validation failures are not trusted`() {
        #expect(!OpenAIDashboardBrowserCookieImporter.shouldTrustVerifiedSession(
            afterPersistFailure: OpenAIDashboardBrowserCookieImporter.ImportError.dashboardStillRequiresLogin))
    }
}
