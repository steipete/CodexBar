import Foundation

extension OpenAIDashboardBrowserCookieImporter.ImportError: UserFacingError {
    public var userMessage: String {
        switch self {
        case .noCookiesFound:
            return "No OpenAI session found in browser"

        case .browserAccessDenied:
            let browser = Self.extractBrowserName(from: self) ?? "Browser"
            return "\(browser) requires Full Disk Access"

        case .dashboardStillRequiresLogin:
            return "OpenAI session has expired"

        case .noMatchingAccount:
            return "Browser logged into different OpenAI account"

        case .manualCookieHeaderInvalid:
            return "Manual cookie header is invalid"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noCookiesFound:
            "Log in to chatgpt.com in your browser"

        case .browserAccessDenied:
            "Go to System Settings → Privacy & Security → Full Disk Access → Enable for CodexBar"

        case .dashboardStillRequiresLogin:
            "Log in again at chatgpt.com"

        case .noMatchingAccount:
            "Log in to chatgpt.com with your Codex account email"

        case .manualCookieHeaderInvalid:
            "Check the cookie header format in Preferences → Advanced"
        }
    }

    public var actionHint: ErrorAction? {
        switch self {
        case .noCookiesFound:
            .openBrowser(url: URL(string: "https://chatgpt.com")!)

        case .browserAccessDenied:
            .openSystemSettings(pane: "Privacy & Security")

        case .dashboardStillRequiresLogin, .noMatchingAccount:
            .openBrowser(url: URL(string: "https://chatgpt.com")!)

        case .manualCookieHeaderInvalid:
            .openPreferences(tab: "Advanced")
        }
    }

    public var technicalDetails: String? {
        switch self {
        case .noCookiesFound:
            return nil

        case let .browserAccessDenied(details):
            return details

        case .dashboardStillRequiresLogin:
            return "Cookies imported but session validation failed"

        case let .noMatchingAccount(found):
            if found.isEmpty {
                return "No accounts found in any browser"
            }
            return "Found accounts: " + found
                .map { "\($0.sourceLabel): \($0.email)" }
                .joined(separator: ", ")

        case .manualCookieHeaderInvalid:
            return "Expected format: Cookie: name=value; name2=value2"
        }
    }

    // MARK: - Private Helpers

    private static func extractBrowserName(from error: OpenAIDashboardBrowserCookieImporter.ImportError) -> String? {
        guard case let .browserAccessDenied(details) = error else { return nil }

        let browsers = [
            "Safari", "Chrome", "Firefox", "Brave", "Edge", "Arc",
            "Opera", "Vivaldi", "Chromium", "Orion", "DuckDuckGo",
        ]
        for browser in browsers where details.contains(browser) {
            return browser
        }
        return nil
    }
}
