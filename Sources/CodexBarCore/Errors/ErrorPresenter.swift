import Foundation

/// Centralizes error-to-message transformation
public enum ErrorPresenter {
    /// Convert any error into a user-friendly displayable error
    public static func present(_ error: Error, context: ErrorContext) -> DisplayableError {
        // Try UserFacingError protocol first
        if let userFacing = error as? UserFacingError {
            return DisplayableError(
                title: self.titleFor(context: context),
                message: userFacing.userMessage,
                suggestion: userFacing.recoverySuggestion,
                action: userFacing.actionHint,
                debugInfo: userFacing.technicalDetails)
        }

        // Handle known error types by pattern matching
        return Self.presentKnownError(error, context: context)
            ?? .generic(from: error, context: context)
    }

    // MARK: - Private Helpers

    private static func titleFor(context: ErrorContext) -> String {
        switch context {
        case .cookieExtraction:
            "Cookie Access Issue"
        case .usageFetch:
            "Usage Fetch Failed"
        case .authentication:
            "Authentication Error"
        case .generic:
            "Error"
        }
    }

    private static func presentKnownError(_ error: Error, context: ErrorContext) -> DisplayableError? {
        // Check error type name for known patterns
        let typeName = String(describing: type(of: error))

        // Handle ImportError from OpenAIDashboardBrowserCookieImporter
        if typeName.contains("ImportError") {
            return Self.presentImportError(error, context: context)
        }

        // Handle ClaudeOAuthFetchError
        if typeName.contains("ClaudeOAuthFetchError") {
            return Self.presentOAuthError(error, context: context)
        }

        // Handle FetchError from ClaudeWebAPIFetcher specifically
        // Avoid matching non-Claude FetchErrors (e.g., OpenAIDashboardFetcher.FetchError)
        if typeName.contains("ClaudeWebAPIFetcher"), typeName.contains("FetchError") {
            return Self.presentFetchError(error, context: context)
        }

        return nil
    }

    private static func presentImportError(_ error: Error, context: ErrorContext) -> DisplayableError? {
        let description = error.localizedDescription

        // noCookiesFound
        if description.contains("No browser cookies found") {
            return .notLoggedIn(
                browser: "Your browser",
                provider: context.providerName ?? "OpenAI",
                loginURL: URL(string: "https://chatgpt.com"))
        }

        // browserAccessDenied - extract browser name if possible
        if description.contains("Browser cookie access denied") {
            // Try to extract browser name from the details
            let browser = Self.extractBrowserName(from: description) ?? "Safari"
            return .permissionDenied(
                browser: browser,
                action: .openSystemSettings(pane: "Privacy & Security"))
        }

        // dashboardStillRequiresLogin
        if description.contains("dashboard still requires login") {
            return DisplayableError(
                title: "Login Required",
                message: "OpenAI session has expired",
                suggestion: "Log in again at chatgpt.com",
                action: .openBrowser(url: URL(string: "https://chatgpt.com")!))
        }

        // noMatchingAccount
        if description.contains("does not match") || description.contains("No matching") {
            return DisplayableError(
                title: "Account Mismatch",
                message: "Browser logged into different OpenAI account",
                suggestion: "Log in to chatgpt.com with your Codex account",
                action: .openBrowser(url: URL(string: "https://chatgpt.com")!),
                debugInfo: description)
        }

        // manualCookieHeaderInvalid
        if description.contains("cookie header invalid") {
            return DisplayableError(
                title: "Invalid Cookies",
                message: "Manual cookie header format is invalid",
                suggestion: "Check your cookie header format in Preferences",
                action: .openPreferences(tab: "Advanced"))
        }

        return nil
    }

    private static func presentFetchError(_ error: Error, context: ErrorContext) -> DisplayableError? {
        let description = error.localizedDescription

        // noSessionKeyFound
        if description.contains("No Claude session key found") || description.contains("session key") {
            // Check for specific sub-errors in the description
            if description.contains("permission denied") {
                let browser = Self.extractBrowserName(from: description) ?? "Browser"
                return .permissionDenied(browser: browser)
            }
            if description.contains("cookies missing") {
                return .notLoggedIn(
                    browser: "Your browser",
                    provider: "Claude",
                    loginURL: URL(string: "https://claude.ai"))
            }
            // Generic session not found
            return DisplayableError(
                title: "Session Not Found",
                message: "No active Claude session in browser",
                suggestion: "Open your browser and log in to claude.ai",
                action: .openBrowser(url: URL(string: "https://claude.ai")!))
        }

        // invalidSessionKey
        if description.contains("Invalid Claude session key") {
            return DisplayableError(
                title: "Invalid Session",
                message: "Claude session key is malformed",
                suggestion: "Clear your browser cookies and log in again",
                action: .openBrowser(url: URL(string: "https://claude.ai")!))
        }

        // unauthorized
        if description.contains("Unauthorized") || description.contains("expired") {
            return .sessionExpired(
                provider: "Claude",
                loginURL: URL(string: "https://claude.ai"))
        }

        // networkError
        if description.contains("Network error") {
            return DisplayableError(
                title: "Network Error",
                message: "Could not connect to Claude",
                suggestion: "Check your internet connection and try again",
                action: .retry,
                debugInfo: description)
        }

        // serverError
        if description.contains("HTTP") || description.contains("API error") {
            return DisplayableError(
                title: "Server Error",
                message: "Claude is temporarily unavailable",
                suggestion: "Try again in a few minutes",
                action: .retry,
                debugInfo: description)
        }

        // noOrganization
        if description.contains("organization") {
            return DisplayableError(
                title: "No Organization",
                message: "No Claude organization found",
                suggestion: "Ensure your Claude account has an active subscription",
                action: .openBrowser(url: URL(string: "https://claude.ai/settings")!))
        }

        return nil
    }

    private static func presentOAuthError(_ error: Error, context: ErrorContext) -> DisplayableError? {
        let description = error.localizedDescription

        if description.contains("unauthorized") || description.contains("Unauthorized") {
            return .sessionExpired(
                provider: context.providerName ?? "Claude",
                loginURL: URL(string: "https://claude.ai"))
        }

        if description.contains("network") || description.contains("Network") {
            return DisplayableError(
                title: "Network Error",
                message: "Could not connect to authentication service",
                suggestion: "Check your internet connection and try again",
                action: .retry)
        }

        return DisplayableError(
            title: "Authentication Error",
            message: "Could not authenticate with Claude",
            suggestion: "Try signing out and back in",
            action: .openPreferences(tab: "Account"),
            debugInfo: description)
    }

    /// Extract browser name from error details
    private static func extractBrowserName(from description: String) -> String? {
        let browsers = [
            "Safari", "Chrome", "Firefox", "Brave", "Edge", "Arc",
            "Opera", "Vivaldi", "Chromium", "Orion", "DuckDuckGo",
        ]
        for browser in browsers where description.contains(browser) {
            return browser
        }
        return nil
    }
}
