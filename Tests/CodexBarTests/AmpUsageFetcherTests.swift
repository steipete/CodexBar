import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct AmpUsageFetcherTests {
    @Test
    func attachesCookieForAmpHosts() {
        #expect(AmpUsageFetcher.shouldAttachCookie(to: URL(string: "https://ampcode.com/settings")))
        #expect(AmpUsageFetcher.shouldAttachCookie(to: URL(string: "https://www.ampcode.com")))
        #expect(AmpUsageFetcher.shouldAttachCookie(to: URL(string: "https://app.ampcode.com/path")))
    }

    @Test
    func rejectsNonAmpHosts() {
        #expect(!AmpUsageFetcher.shouldAttachCookie(to: URL(string: "https://example.com")))
        #expect(!AmpUsageFetcher.shouldAttachCookie(to: URL(string: "https://ampcode.com.evil.com")))
        #expect(!AmpUsageFetcher.shouldAttachCookie(to: nil))
    }
}
