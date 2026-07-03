import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeOAuthCredentialHistoryLinuxTests {
    @Test
    func historyOwnerIdentifierUsesSwiftCrypto() throws {
        let first = ClaudeOAuthCredentials(
            accessToken: "access-token-a",
            refreshToken: "refresh-token-a",
            expiresAt: Date(timeIntervalSinceNow: 3600),
            scopes: ["user:profile"],
            rateLimitTier: nil)
        let second = ClaudeOAuthCredentials(
            accessToken: "access-token-b",
            refreshToken: "refresh-token-b",
            expiresAt: Date(timeIntervalSinceNow: 3600),
            scopes: ["user:profile"],
            rateLimitTier: nil)

        let firstIdentifier = try #require(first.historyOwnerIdentifier)
        let secondIdentifier = try #require(second.historyOwnerIdentifier)
        #expect(firstIdentifier.count == 64)
        #expect(firstIdentifier != secondIdentifier)
        #expect(firstIdentifier.allSatisfy { $0.isHexDigit })
    }
}
