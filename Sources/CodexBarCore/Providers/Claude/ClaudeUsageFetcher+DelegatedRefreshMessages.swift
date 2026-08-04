import Foundation

/// Presentation helpers for delegated Claude CLI refresh outcomes, split out to keep ClaudeUsageFetcher.swift
/// within the file-length limit.
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
        case .unreadableAfterRefresh:
            "unreadableAfterRefresh"
        }
    }

    static func delegatedRefreshFailureMessage(
        for outcome: ClaudeOAuthDelegatedRefreshCoordinator.Outcome,
        retryError: Error) -> String
    {
        if let oauthError = retryError as? ClaudeOAuthFetchError,
           case .rateLimited = oauthError
        {
            return oauthError.localizedDescription
        }

        switch outcome {
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
        case .unreadableAfterRefresh:
            // Deliberately not "run `claude login`, then retry": Claude Code would refresh its own Keychain item,
            // which CodexBar does not read, so the same expired cache would come back.
            return "Claude OAuth credentials expired and CodexBar cannot read them back. Claude Code owns the "
                + "Keychain item and no credentials file is present for this profile, so refreshing will not "
                + "restore usage. Switch Claude Usage source to Web/CLI."
        }
    }
}
