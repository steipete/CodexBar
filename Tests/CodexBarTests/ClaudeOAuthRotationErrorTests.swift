import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeOAuthRotationErrorTests {
    @Test
    func `logged in profile with a prior Keychain grant reports revoked access`() {
        let error = ClaudeOAuthCredentialsStore.classifyTerminalMissingCredentialsError(
            directReadConsentGranted: true,
            keychainAccessDisabled: false,
            keychainAccessDenied: false,
            previousKeychainGrantRecorded: true,
            loggedInProfilePresent: true)

        #expect(error.localizedDescription.contains("token rotation"))
        #expect(error.localizedDescription.contains("Click Refresh"))
        #expect(error.localizedDescription.contains("CLI/Web"))
    }

    @Test
    func `profile without current login evidence still reports missing credentials`() {
        let error = ClaudeOAuthCredentialsStore.classifyTerminalMissingCredentialsError(
            directReadConsentGranted: true,
            keychainAccessDisabled: false,
            keychainAccessDenied: false,
            previousKeychainGrantRecorded: true,
            loggedInProfilePresent: false)

        guard case .notFound = error else {
            Issue.record("Expected a genuinely absent item to remain notFound")
            return
        }
    }

    @Test
    @MainActor
    func `Claude rotation error localizes and includes stale capture age`() throws {
        let raw = ClaudeOAuthCredentialsError.keychainAccessRevoked.localizedDescription
        let message = try #require(ClaudeUIErrorMapper.userFacingMessage(
            raw,
            staleSnapshotUpdatedAt: Date(timeIntervalSinceNow: -5 * 60),
            localize: { key in
                switch key {
                case "claude_oauth_keychain_access_revoked": "localized revoked access"
                case "claude_showing_last_known_usage": "stale capture %@"
                default: key
                }
            }))

        #expect(message.hasPrefix("localized revoked access stale capture "))
    }
}
