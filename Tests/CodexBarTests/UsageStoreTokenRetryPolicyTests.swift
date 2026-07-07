import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageStoreTokenRetryPolicyTests {
    @Test
    func `timed out token scans keep the fetch TTL while fast failures retry early`() {
        #expect(!UsageStore.tokenFetchFailureAllowsEarlyRetry(CostUsageError.timedOut(seconds: 600)))
        #expect(UsageStore.tokenFetchFailureAllowsEarlyRetry(CocoaError(.fileReadNoSuchFile)))
    }
}
