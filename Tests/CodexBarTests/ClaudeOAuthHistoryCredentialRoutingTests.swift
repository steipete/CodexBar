import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthHistoryCredentialRoutingTests {
    @Test
    func `history keychain reference only matches the credential that won routing`() throws {
        let keychainData = self.makeCredentialsData(accessToken: "keychain-token")
        let keychainCredentials = try ClaudeOAuthCredentials.parse(data: keychainData)
        let differentCredentials = try ClaudeOAuthCredentials.parse(
            data: self.makeCredentialsData(accessToken: "different-token"))
        let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 1,
            createdAt: 1,
            persistentRefHash: "opaque-ref")

        let matchingCLIRecord = ClaudeOAuthCredentialRecord(
            credentials: keychainCredentials,
            owner: .claudeCLI,
            source: .memoryCache)
        let differentCLIRecord = ClaudeOAuthCredentialRecord(
            credentials: differentCredentials,
            owner: .claudeCLI,
            source: .credentialsFile)
        let matchingEnvironmentRecord = ClaudeOAuthCredentialRecord(
            credentials: keychainCredentials,
            owner: .environment,
            source: .environment)
        let matchingCodexBarRecord = ClaudeOAuthCredentialRecord(
            credentials: keychainCredentials,
            owner: .codexbar,
            source: .cacheKeychain)

        ProviderInteractionContext.$current.withValue(.userInitiated) {
            ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                    data: keychainData,
                    fingerprint: fingerprint)
                {
                    #expect(ClaudeOAuthCredentialsStore
                        .matchingClaudeKeychainPersistentRefHashWithoutPrompt(for: matchingCLIRecord) == "opaque-ref")
                    #expect(ClaudeOAuthCredentialsStore
                        .matchingClaudeKeychainPersistentRefHashWithoutPrompt(for: differentCLIRecord) == nil)
                    #expect(ClaudeOAuthCredentialsStore
                        .matchingClaudeKeychainPersistentRefHashWithoutPrompt(for: matchingEnvironmentRecord) == nil)
                    #expect(ClaudeOAuthCredentialsStore
                        .matchingClaudeKeychainPersistentRefHashWithoutPrompt(for: matchingCodexBarRecord) == nil)
                }
            }
        }
    }

    @Test
    func `newest duplicate reference cannot label a different winning credential`() throws {
        let winningCredentials = try ClaudeOAuthCredentials.parse(
            data: self.makeCredentialsData(accessToken: "winning-token"))
        let newestCandidateCredentials = try ClaudeOAuthCredentials.parse(
            data: self.makeCredentialsData(accessToken: "newest-candidate-token"))
        let winningRecord = ClaudeOAuthCredentialRecord(
            credentials: winningCredentials,
            owner: .claudeCLI,
            source: .memoryCache)
        let newestCandidateRecord = ClaudeOAuthCredentialRecord(
            credentials: newestCandidateCredentials,
            owner: .claudeCLI,
            source: .claudeKeychain)

        #expect(ClaudeOAuthCredentialsStore._matchingClaudeKeychainPersistentRefHashForTesting(
            record: winningRecord,
            candidateCredentials: newestCandidateCredentials,
            persistentRefHash: "newest-candidate-ref") == nil)
        #expect(ClaudeOAuthCredentialsStore._matchingClaudeKeychainPersistentRefHashForTesting(
            record: newestCandidateRecord,
            candidateCredentials: newestCandidateCredentials,
            persistentRefHash: "newest-candidate-ref") == "newest-candidate-ref")
    }

    @Test
    func `history owner follows refresh credential across access token rotation`() throws {
        let beforeRefresh = try ClaudeOAuthCredentials.parse(
            data: self.makeCredentialsData(accessToken: "access-before", refreshToken: "stable-refresh"))
        let afterRefresh = try ClaudeOAuthCredentials.parse(
            data: self.makeCredentialsData(accessToken: "access-after", refreshToken: "stable-refresh"))

        let beforeIdentifier = try #require(beforeRefresh.historyOwnerIdentifier)
        let afterIdentifier = try #require(afterRefresh.historyOwnerIdentifier)
        #expect(beforeIdentifier == afterIdentifier)
        #expect(beforeIdentifier.count == 64)
        #expect(!beforeIdentifier.contains("stable-refresh"))
    }

    @Test
    func `access-only credential replacement rotates history owner`() throws {
        let original = try ClaudeOAuthCredentials.parse(
            data: self.makeCredentialsData(accessToken: "original-access"))
        let replacement = try ClaudeOAuthCredentials.parse(
            data: self.makeCredentialsData(accessToken: "replacement-access"))

        let originalIdentifier = try #require(original.historyOwnerIdentifier)
        let replacementIdentifier = try #require(replacement.historyOwnerIdentifier)
        #expect(originalIdentifier != replacementIdentifier)
        #expect(!originalIdentifier.contains("original-access"))
        #expect(!replacementIdentifier.contains("replacement-access"))
    }

    @Test
    func `only an explicit refresh lineage can preserve a rotated credential owner`() throws {
        let original = try ClaudeOAuthCredentials.parse(
            data: self.makeCredentialsData(accessToken: "access-before", refreshToken: "refresh-before"))
        let rotated = try ClaudeOAuthCredentials.parse(
            data: self.makeCredentialsData(accessToken: "access-after", refreshToken: "refresh-after"))
        let originalIdentifier = try #require(original.historyOwnerIdentifier)
        let rotatedIdentifier = try #require(rotated.historyOwnerIdentifier)
        #expect(originalIdentifier != rotatedIdentifier)

        let refreshProvenRecord = ClaudeOAuthCredentialRecord(
            credentials: rotated,
            owner: .codexbar,
            source: .memoryCache,
            historyOwnerIdentifier: originalIdentifier)
        let unrelatedReplacementRecord = ClaudeOAuthCredentialRecord(
            credentials: rotated,
            owner: .codexbar,
            source: .cacheKeychain)

        #expect(refreshProvenRecord.historyOwnerIdentifier == originalIdentifier)
        #expect(unrelatedReplacementRecord.historyOwnerIdentifier == rotatedIdentifier)
    }

    private func makeCredentialsData(accessToken: String, refreshToken: String? = nil) -> Data {
        let expiresAt = Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970 * 1000)
        let refreshTokenJSON = refreshToken.map { "\n            \"refreshToken\": \"\($0)\"," } ?? ""
        return Data("""
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            \(refreshTokenJSON)
            "expiresAt": \(expiresAt),
            "scopes": ["user:profile"]
          }
        }
        """.utf8)
    }
}
