#if os(Linux)
import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeOAuthUsageRateLimitGateLinuxTests {
    @Test
    func `rate limit gate isolates tokens without storing raw credentials`() {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        defer { ClaudeOAuthUsageRateLimitGate.resetForTesting() }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tokenA = "linux-account-a"
        let tokenB = "linux-account-b"
        let keyA = ClaudeOAuthUsageRateLimitGate.storageKeyForTesting(accessToken: tokenA)
        let keyB = ClaudeOAuthUsageRateLimitGate.storageKeyForTesting(accessToken: tokenB)

        ClaudeOAuthUsageRateLimitGate.recordRateLimit(
            accessToken: tokenA,
            retryAfter: now.addingTimeInterval(120),
            now: now)

        #expect(keyA != keyB)
        #expect(!keyA.contains(tokenA))
        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(accessToken: tokenA, now: now) != nil)
        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(accessToken: tokenB, now: now) == nil)
    }
}
#endif
