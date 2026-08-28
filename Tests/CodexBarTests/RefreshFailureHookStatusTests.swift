import Foundation
import Testing
@testable import CodexBar

struct RefreshFailureHookStatusTests {
    @Test
    func `maps URL errors to coarse categories`() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(UsageStore.refreshFailureHookStatus(timeout) == "timeout")

        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(UsageStore.refreshFailureHookStatus(offline) == "offline")

        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(UsageStore.refreshFailureHookStatus(cancelled) == "cancelled")

        #expect(UsageStore.refreshFailureHookStatus(CancellationError()) == "cancelled")
    }

    @Test
    func `never forwards the raw error description`() {
        // A provider error whose description embeds a response-body preview must not
        // leak into the hook status.
        let leaky = NSError(
            domain: "ProviderHTTP",
            code: 500,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 500: {\"error\":\"secret-token abc123\"}"])
        let status = UsageStore.refreshFailureHookStatus(leaky)
        #expect(status == "error")
        #expect(!status.contains("secret-token"))
        #expect(!status.contains("500"))
    }
}
