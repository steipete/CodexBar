import Foundation

extension ClaudeUsageError: UserFacingError {
    public var userMessage: String {
        switch self {
        case .claudeNotInstalled:
            "Claude CLI is not installed"
        case .parseFailed:
            "Could not parse Claude usage"
        case .oauthFailed:
            "Claude OAuth authentication failed"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .claudeNotInstalled:
            "Install the Claude CLI or switch Claude Source in Preferences → Providers."
        case .parseFailed:
            "Try again or switch Claude Source in Preferences → Providers."
        case let .oauthFailed(details):
            details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Re-authenticate with Claude or switch Claude Source."
                : details.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public var actionHint: ErrorAction? {
        switch self {
        case .claudeNotInstalled:
            .openBrowser(url: URL(string: "https://docs.claude.ai/claude-code")!)
        case .parseFailed, .oauthFailed:
            .openPreferences(tab: "Providers")
        }
    }

    public var technicalDetails: String? {
        switch self {
        case let .parseFailed(details),
             let .oauthFailed(details):
            details
        case .claudeNotInstalled:
            nil
        }
    }
}
