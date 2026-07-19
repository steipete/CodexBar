#if os(macOS)
import AppKit
import Testing
@testable import CodexBarCore

@MainActor
struct WebKitTeardownTests {
    final class Owner {}

    @Test
    func `schedule cleanup registers owner`() {
        let owner = Owner()
        WebKitTeardown.resetForTesting()
        WebKitTeardown.scheduleCleanup(owner: owner, window: nil, webView: nil)

        #expect(WebKitTeardown.isRetainedForTesting(owner))
        #expect(WebKitTeardown.isScheduledForTesting(owner))

        WebKitTeardown.resetForTesting()
        #expect(!WebKitTeardown.isRetainedForTesting(owner))
        #expect(!WebKitTeardown.isScheduledForTesting(owner))
    }
}
#endif
