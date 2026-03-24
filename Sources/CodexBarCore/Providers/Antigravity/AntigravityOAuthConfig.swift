import Foundation

/// Central configuration for Antigravity OAuth credentials.
///
/// The owner should provide the actual credentials via environment variables
/// or by replacing the placeholder values below.
///
/// Environment variables (take priority):
///   - `ANTIGRAVITY_OAUTH_CLIENT_ID`
///   - `ANTIGRAVITY_OAUTH_CLIENT_SECRET`
public enum AntigravityOAuthConfig: Sendable {
    /// Google OAuth Client ID for the Cloud Code extension.
    public static var clientId: String {
        ProcessInfo.processInfo.environment["ANTIGRAVITY_OAUTH_CLIENT_ID"]
            ?? "REPLACE_WITH_OAUTH_CLIENT_ID"
    }

    /// Google OAuth Client Secret for the Cloud Code extension.
    public static var clientSecret: String {
        ProcessInfo.processInfo.environment["ANTIGRAVITY_OAUTH_CLIENT_SECRET"]
            ?? "REPLACE_WITH_OAUTH_CLIENT_SECRET"
    }
}
