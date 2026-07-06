import Foundation

/// Shared copy for Google's June 2026 Gemini CLI consumer-tier shutdown.
public enum GeminiConsumerTierMigration {
    public static let deprecationError = """
    Google no longer supports Gemini CLI OAuth for individual, AI Pro, or Ultra accounts. \
    Enable CodexBar's Antigravity provider, sign in to Antigravity or run `agy`, then refresh.
    """

    public static let terminalLoginGuidance = """
    Complete sign-in in Terminal. If Google shows UNSUPPORTED_CLIENT or asks you to migrate to Antigravity, \
    Gemini CLI no longer supports your account tier—enable CodexBar's Antigravity provider instead.
    """

    public static let notLoggedInHint = """
    If Terminal shows UNSUPPORTED_CLIENT, Google blocked Gemini CLI for your account tier—use Antigravity instead.
    """

    public static let antigravitySetupHint = """
    If Google blocked Gemini CLI OAuth for your account, Antigravity replaces Gemini for quota tracking.
    """
}
