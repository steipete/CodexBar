import CodexBarCore
import Foundation

@MainActor
enum ClaudeUIErrorMapper {
    static func userFacingMessage(
        _ raw: String?,
        staleSnapshotUpdatedAt: Date?,
        localize: (String) -> String = L) -> String?
    {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let message = if trimmed == ClaudeOAuthCredentialsError.keychainAccessRevoked.localizedDescription {
            localize("claude_oauth_keychain_access_revoked")
        } else {
            trimmed
        }
        guard let staleSnapshotUpdatedAt else { return message }
        return message + " " + String(
            format: localize("claude_showing_last_known_usage"),
            staleSnapshotUpdatedAt.relativeDescription())
    }
}
