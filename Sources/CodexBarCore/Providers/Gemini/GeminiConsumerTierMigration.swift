import Foundation

/// Shared copy for Google's June 2026 Gemini CLI consumer-tier shutdown.
public enum GeminiConsumerTierMigration {
    public static let deprecationError = """
    Google no longer supports Gemini CLI OAuth for individual, AI Pro, or Ultra accounts. \
    Enable CodexBar's Antigravity provider, sign in to Antigravity or run `agy`, then refresh.
    """

    /// Explains the one reason to continue into a Gemini CLI sign-in after the shutdown was detected:
    /// moving to an account Google still serves. Signing in clears the stored credentials first.
    public static let loginSwitchAccountPrompt = """
    Signing in again only helps if you are switching to a Workspace, education, or Code Assist \
    Standard/Enterprise account. Continuing clears the stored Gemini credentials and opens Gemini CLI.
    """

    public static let oauthRecoveryError = """
    Could not refresh Gemini OAuth credentials. Reinstall or update Gemini CLI, or set \
    GEMINI_OAUTH_CLIENT_ID and GEMINI_OAUTH_CLIENT_SECRET. Consumer Google AI Pro/Ultra \
    accounts blocked by the June 2026 Gemini CLI shutdown should use CodexBar's Antigravity \
    provider instead. Workspace and education accounts should keep using Gemini.
    """

    public static let localAntigravityHandoffError = """
    Could not refresh Gemini OAuth credentials from Gemini CLI. Enable CodexBar's Antigravity \
    provider, sign in to Antigravity or run `agy`, then refresh.
    """

    static func isAntigravityAvailable() -> Bool {
        if BinaryLocator.resolveAntigravityBinary() != nil {
            return true
        }

        return AntigravityOAuthConfig.candidateOAuthClientArtifactURLs().contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}
