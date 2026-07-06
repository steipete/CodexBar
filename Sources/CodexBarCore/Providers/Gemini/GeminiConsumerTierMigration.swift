import Foundation

/// Shared copy for Google's June 2026 Gemini CLI consumer-tier shutdown.
public enum GeminiConsumerTierMigration {
    public static let deprecationError = """
    Google no longer supports Gemini CLI OAuth for individual, AI Pro, or Ultra accounts. \
    Enable CodexBar's Antigravity provider, sign in to Antigravity or run `agy`, then refresh.
    """
}
