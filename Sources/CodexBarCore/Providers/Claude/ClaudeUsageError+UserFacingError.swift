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
            return "Install the Claude CLI or switch Claude Source in Preferences → Providers."
        case .parseFailed:
            return "Try again or switch Claude Source in Preferences → Providers."
        case let .oauthFailed(details):
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Re-authenticate with Claude or switch Claude Source." : trimmed
        }
    }

    public var actionHint: ErrorAction? {
        switch self {
        case .claudeNotInstalled:
            return .openBrowser(url: URL(string: "https://docs.claude.ai/claude-code")!)
        case .parseFailed, .oauthFailed:
            return .openPreferences(tab: "Providers")
        }
    }

    public var technicalDetails: String? {
        switch self {
        case let .parseFailed(details),
             let .oauthFailed(details):
            return details
        case .claudeNotInstalled:
            return nil
        }
    }
}
