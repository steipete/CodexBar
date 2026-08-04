import Foundation

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
            // build never reads, so the same expired cache comes back.
            return "Claude OAuth credentials expired and CodexBar cannot read them back. Claude Code owns the "
                + "Keychain item and no credentials file is present for this profile, so refreshing will not "
                + "restore usage. Switch Claude Usage source to Web/CLI."
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
