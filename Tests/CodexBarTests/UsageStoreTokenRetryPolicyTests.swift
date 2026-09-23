import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStoreTokenRetryPolicyTests {
    @Test(arguments: [401, 403])
    func `Cursor HTTP authorization failures keep the fetch TTL`(status: Int) {
        #expect(!UsageStore.tokenFetchFailureAllowsEarlyRetry(CursorStatusProbeError.networkError("HTTP \(status)")))
    }

    @Test
    func `Cursor login rejection keeps the fetch TTL`() {
        #expect(!UsageStore.tokenFetchFailureAllowsEarlyRetry(CursorStatusProbeError.notLoggedIn))
    }

    @Test(arguments: ["HTTP 429", "HTTP 500", "HTTP 503", "Connection lost"])
    func `transient Cursor failures still retry early`(message: String) {
        #expect(UsageStore.tokenFetchFailureAllowsEarlyRetry(CursorStatusProbeError.networkError(message)))
    }

    @Test
    func `timed out token scans keep the fetch TTL while fast failures retry early`() {
        #expect(!UsageStore.tokenFetchFailureAllowsEarlyRetry(CostUsageError.timedOut(seconds: 600)))
        #expect(UsageStore.tokenFetchFailureAllowsEarlyRetry(CocoaError(.fileReadNoSuchFile)))
    }
}
