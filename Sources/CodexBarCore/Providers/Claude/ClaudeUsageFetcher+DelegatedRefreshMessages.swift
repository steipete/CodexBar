import Foundation

/// Terminal state from #2634/#2650: the delegated Claude CLI touch completed cleanly, but Claude Code's
/// Keychain item is not readable (no direct-read consent) and no credentials file exists for the profile,
/// so retrying cannot restore OAuth usage. Typed so the fetch pipeline can fall back to reading usage from
/// the Claude CLI itself instead of trapping the user on an unrecoverable OAuth error.
public struct ClaudeOAuthUnreadableCredentialsError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        self.message
    }

    /// The stable lead-in used to recognize this state from a persisted error string (e.g. for the
    /// provider-card call to action after the error crossed an untyped boundary).
    public static let descriptionPrefix = "Claude OAuth credentials expired and CodexBar cannot read them back"

    public static func matches(description: String?) -> Bool {
        description?.hasPrefix(self.descriptionPrefix) ?? false
    }
}

/// Split out of `ClaudeUsageFetcher.swift` to keep that file within the file-length limit.
extension ClaudeUsageFetcher {
    static func delegatedRefreshOutcomeLabel(
        _ outcome: ClaudeOAuthDelegatedRefreshCoordinator.Outcome) -> String
    {
        switch outcome {
        case .skippedByCooldown:
            "skippedByCooldown"
        case .skippedByPromptPolicy:
            "skippedByPromptPolicy"
        case .cliUnavailable:
            "cliUnavailable"
        case .attemptedSucceeded:
            "attemptedSucceeded"
        case .attemptedFailed:
            "attemptedFailed"
        }
    }

    /// The unreadable terminal state comes back as the typed `ClaudeOAuthUnreadableCredentialsError` so the
    /// pipeline can hand off to the Claude CLI usage fallback; everything else stays a plain OAuth failure.
    static func delegatedRefreshFailureError(
        for result: ClaudeOAuthDelegatedRefreshCoordinator.AttemptResult,
        retryError: Error) -> Error
    {
        let message = self.delegatedRefreshFailureMessage(for: result, retryError: retryError)
        var isRateLimited = false
        if let oauthError = retryError as? ClaudeOAuthFetchError, case .rateLimited = oauthError {
            isRateLimited = true
        }
        if result.isUnreadableAfterRefresh, !isRateLimited {
            return ClaudeOAuthUnreadableCredentialsError(message: message)
        }
        return ClaudeUsageError.oauthFailed(message)
    }

    static func delegatedRefreshFailureMessage(
        for result: ClaudeOAuthDelegatedRefreshCoordinator.AttemptResult,
        retryError: Error) -> String
    {
        if let oauthError = retryError as? ClaudeOAuthFetchError,
           case .rateLimited = oauthError
        {
            return oauthError.localizedDescription
        }

        if result.isUnreadableAfterRefresh {
            // Not "run `claude login`, then retry": that refreshes Claude Code's own Keychain item, which this
            // build does not read without consent, so the same expired cache comes back.
            return ClaudeOAuthUnreadableCredentialsError.descriptionPrefix
                + ": Claude Code keeps them only in its own Keychain item, which CodexBar reads only with your "
                + "permission. Enable \u{201C}Allow reading Claude Code credentials\u{201D} in Claude settings to "
                + "restore OAuth usage, or CodexBar uses the Claude CLI when it is available."
        }

        switch result.outcome {
        case .skippedByCooldown:
            return "Claude OAuth token expired and delegated refresh is cooling down. "
                + "Please retry shortly, or run `claude login`."
        case .skippedByPromptPolicy:
            return "Claude OAuth token expired; background refresh is disabled by the Keychain prompt policy. "
                + "Refresh CodexBar manually or run `claude login`."
        case .cliUnavailable:
            return "Claude OAuth token expired and Claude CLI is not available for delegated refresh. "
                + "Install/configure `claude`, or run `claude login`."
        case .attemptedSucceeded:
            return "Claude OAuth token is still unavailable after delegated Claude CLI refresh. "
                + "Run `claude login`, then retry."
        case let .attemptedFailed(message):
            return "Claude OAuth token expired and delegated Claude CLI refresh failed: \(message). "
                + "Run `claude login`, then retry."
        }
    }
}
