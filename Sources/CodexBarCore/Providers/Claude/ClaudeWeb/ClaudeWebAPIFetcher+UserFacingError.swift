import Foundation

extension ClaudeWebAPIFetcher.FetchError: UserFacingError {
    public var userMessage: String {
        switch self {
        case let .noSessionKeyFound(report):
            if let report, let summary = Self.extractMainIssue(from: report) {
                return summary
            }
            return "No active Claude session found in browser"

        case .invalidSessionKey:
            return "Claude session is invalid"

        case .notSupportedOnThisPlatform:
            return "Claude web access requires macOS"

        case .networkError:
            return "Could not connect to Claude"

        case .invalidResponse:
            return "Received unexpected response from Claude"

        case .unauthorized:
            return "Claude session has expired"

        case let .serverError(code):
            if code >= 500 {
                return "Claude is temporarily unavailable"
            }
            return "Claude request failed"

        case .noOrganization:
            return "No Claude organization found"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case let .noSessionKeyFound(report):
            Self.suggestRecovery(from: report)

        case .invalidSessionKey:
            "Clear browser cookies and log in to claude.ai again"

        case .notSupportedOnThisPlatform:
            nil

        case .networkError:
            "Check your internet connection and try again"

        case .invalidResponse:
            "Try again in a few minutes"

        case .unauthorized:
            "Log in again at claude.ai"

        case .serverError:
            "Try again in a few minutes"

        case .noOrganization:
            "Check your Claude subscription at claude.ai/settings"
        }
    }

    public var actionHint: ErrorAction? {
        switch self {
        case let .noSessionKeyFound(report):
            if Self.hasPermissionError(in: report) {
                return .openSystemSettings(pane: "Privacy & Security")
            }
            return .openBrowser(url: URL(string: "https://claude.ai")!)

        case .invalidSessionKey, .unauthorized:
            return .openBrowser(url: URL(string: "https://claude.ai")!)

        case .notSupportedOnThisPlatform:
            return nil

        case .networkError, .invalidResponse, .serverError:
            return .retry

        case .noOrganization:
            return .openBrowser(url: URL(string: "https://claude.ai/settings")!)
        }
    }

    public var technicalDetails: String? {
        switch self {
        case let .noSessionKeyFound(report):
            // Include the full diagnostic report for debugging
            report?.events
                .map { "[\($0.level.logLabel)] \($0.browser ?? "General"): \($0.message)" }
                .joined(separator: "\n")

        case let .networkError(error):
            error.localizedDescription

        case let .serverError(code):
            "HTTP status code: \(code)"

        default:
            nil
        }
    }

    // MARK: - Private Helpers

    private static func extractMainIssue(from report: CookieExtractionReport) -> String? {
        // Find the most significant error/warning
        let errors = report.events.filter { $0.level == .error }
        let warnings = report.events.filter { $0.level == .warning }

        // Permission denied is the most actionable
        if Self.hasPermissionError(in: report) {
            let browser = Self.browserWithPermissionError(in: report) ?? "Browser"
            return "\(browser) requires Full Disk Access"
        }

        // No cookies found
        if errors.contains(where: { $0.category == .noCookieFiles }) ||
            warnings.contains(where: { $0.category == .noCookieFiles })
        {
            return "Browser not logged in to Claude"
        }

        // Parse/read failures
        if !errors.isEmpty {
            let browser = errors.first?.browser ?? "Browser"
            return "\(browser) cookies could not be read"
        }

        return nil
    }

    private static func suggestRecovery(from report: CookieExtractionReport?) -> String? {
        guard let report else {
            return "Open your browser and log in to claude.ai"
        }

        // Permission denied → system settings
        if Self.hasPermissionError(in: report) {
            return "Go to System Settings → Privacy & Security → Full Disk Access → Enable for CodexBar"
        }

        // No cookies → login
        if report.events.contains(where: { $0.category == .noCookieFiles }) {
            return "Open your browser and log in to claude.ai"
        }

        return "Log in to claude.ai in your browser"
    }

    private static func hasPermissionError(in report: CookieExtractionReport?) -> Bool {
        report?.events.contains { $0.category == .cookieFileUnreadable } ?? false
    }

    private static func browserWithPermissionError(in report: CookieExtractionReport?) -> String? {
        report?.events.first { $0.category == .cookieFileUnreadable }?.browser
    }
}
