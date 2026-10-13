import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct ClaudeUIErrorMapperTests {
    @Test(arguments: [
        ClaudeOAuthCredentialsError.missingAccessToken,
        .missingOAuth,
        .notFound,
    ])
    func `explicitly disabled Keychain replaces missing sign in advice`(error: ClaudeOAuthCredentialsError) {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            let message = ClaudeUIErrorMapper.userFacingMessage(error.localizedDescription, staleSnapshotUpdatedAt: nil)
            #expect(message == L("claude_oauth_keychain_access_disabled"))
            #expect(message?.contains("Run `claude`") == false)
        }
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            #expect(ClaudeUIErrorMapper.userFacingMessage(error.localizedDescription, staleSnapshotUpdatedAt: nil)
                == error.localizedDescription)
        }
    }

    @Test
    func `disabled Keychain preserves unrelated errors and appends stale notice once`() throws {
        let raw = ClaudeOAuthCredentialsError.refreshFailed("Synthetic server failure").localizedDescription
        #expect(ClaudeUIErrorMapper.userFacingMessage(raw, staleSnapshotUpdatedAt: nil, keychainAccessDisabled: true)
            == raw)
        let message = try #require(ClaudeUIErrorMapper.userFacingMessage(
            ClaudeOAuthCredentialsError.missingAccessToken.localizedDescription,
            staleSnapshotUpdatedAt: Date(),
            keychainAccessDisabled: true,
            localize: { key in
                key == "claude_oauth_keychain_access_disabled" ? "Keychain disabled" : "Stale capture %@"
            }))
        #expect(message.hasPrefix("Keychain disabled Stale capture "))
        #expect(message.components(separatedBy: "Stale capture").count == 2)
    }
}
