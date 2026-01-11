import Foundation
import Testing

#if os(macOS)
@testable import CodexBarCore

@Suite
struct ErrorPresentationTests {
    // MARK: - UserFacingError Protocol Tests

    @Test
    func claudeFetchErrorNoSessionUserMessage() {
        let error = ClaudeWebAPIFetcher.FetchError.noSessionKeyFound(report: nil)
        #expect(error.userMessage == "No active Claude session found in browser")
    }

    @Test
    func claudeFetchErrorUnauthorizedUserMessage() {
        let error = ClaudeWebAPIFetcher.FetchError.unauthorized
        #expect(error.userMessage == "Claude session has expired")
        #expect(error.recoverySuggestion == "Log in again at claude.ai")
    }

    @Test
    func claudeFetchErrorNetworkUserMessage() {
        let underlyingError = URLError(.notConnectedToInternet)
        let error = ClaudeWebAPIFetcher.FetchError.networkError(underlyingError)
        #expect(error.userMessage == "Could not connect to Claude")
        #expect(error.recoverySuggestion == "Check your internet connection and try again")
    }

    @Test
    func claudeFetchErrorServerUserMessage() {
        let error = ClaudeWebAPIFetcher.FetchError.serverError(statusCode: 500)
        #expect(error.userMessage == "Claude is temporarily unavailable")
        #expect(error.recoverySuggestion == "Try again in a few minutes")
    }

    @Test
    func claudeFetchErrorNoOrgUserMessage() {
        let error = ClaudeWebAPIFetcher.FetchError.noOrganization
        #expect(error.userMessage == "No Claude organization found")
    }

    // MARK: - OpenAI ImportError Tests

    @Test
    func openAIImportErrorNoCookiesUserMessage() {
        let error = OpenAIDashboardBrowserCookieImporter.ImportError.noCookiesFound
        #expect(error.userMessage == "No OpenAI session found in browser")
        #expect(error.recoverySuggestion == "Log in to chatgpt.com in your browser")
    }

    @Test
    func openAIImportErrorAccessDeniedUserMessage() {
        let error = OpenAIDashboardBrowserCookieImporter.ImportError.browserAccessDenied(
            details: "Safari cookie file exists but is not readable")
        #expect(error.userMessage.contains("Full Disk Access"))
        #expect(error.recoverySuggestion?.contains("System Settings") == true)
    }

    @Test
    func openAIImportErrorDashboardLoginUserMessage() {
        let error = OpenAIDashboardBrowserCookieImporter.ImportError.dashboardStillRequiresLogin
        #expect(error.userMessage == "OpenAI session has expired")
        #expect(error.recoverySuggestion == "Log in again at chatgpt.com")
    }

    // MARK: - ErrorPresenter Tests

    @Test
    func presenterConvertsUserFacingError() {
        let error = ClaudeWebAPIFetcher.FetchError.unauthorized
        let displayable = ErrorPresenter.present(error, context: .usageFetch(provider: "Claude"))

        #expect(displayable.message == "Claude session has expired")
        #expect(displayable.suggestion == "Log in again at claude.ai")
    }

    @Test
    func presenterFallsBackForUnknownErrors() {
        struct UnknownError: Error {}
        let displayable = ErrorPresenter.present(UnknownError(), context: .generic)

        #expect(displayable.message == "Something went wrong")
        #expect(displayable.suggestion == "Please try again later")
    }

    // MARK: - DisplayableError Tests

    @Test
    func displayableErrorStatusBarText() {
        let error = DisplayableError(
            title: "Test",
            message: "Browser not found",
            suggestion: "Open Chrome")

        #expect(error.statusBarText == "Browser not found. Open Chrome")
    }

    @Test
    func displayableErrorStatusBarTextWithoutSuggestion() {
        let error = DisplayableError(
            title: "Test",
            message: "Something happened")

        #expect(error.statusBarText == "Something happened")
    }

    @Test
    func displayableErrorPermissionDenied() {
        let error = DisplayableError.permissionDenied(browser: "Safari")

        #expect(error.title == "Permission Required")
        #expect(error.message.contains("Safari"))
        #expect(error.message.contains("Full Disk Access"))
        #expect(error.suggestion?.contains("System Settings") == true)
    }

    @Test
    func displayableErrorNotLoggedIn() {
        let error = DisplayableError.notLoggedIn(
            browser: "Chrome",
            provider: "Claude",
            loginURL: URL(string: "https://claude.ai"))

        #expect(error.title == "Login Required")
        #expect(error.message.contains("Chrome"))
        #expect(error.message.contains("Claude"))
        #expect(error.suggestion?.contains("claude.ai") == true)
    }

    @Test
    func displayableErrorSessionExpired() {
        let error = DisplayableError.sessionExpired(
            provider: "Claude",
            loginURL: URL(string: "https://claude.ai"))

        #expect(error.title == "Session Expired")
        #expect(error.message.contains("Claude"))
        #expect(error.suggestion?.contains("log in") == true)
    }

    // MARK: - No File Paths Exposed

    @Test
    func noFilePathsInUserMessage() {
        // Create an error with technical file path details
        let cookiePath =
            "/Users/test/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
        let error = OpenAIDashboardBrowserCookieImporter.ImportError.browserAccessDenied(
            details: "Safari cookie file exists but is not readable (\(cookiePath))")

        let displayable = ErrorPresenter.present(error, context: .cookieExtraction(provider: "OpenAI"))

        // User-facing message should NOT contain file paths
        #expect(!displayable.message.contains("/Users"))
        #expect(!displayable.message.contains("/Library"))
        #expect(!displayable.message.contains(".binarycookies"))

        // Technical details CAN contain file paths
        #expect(displayable.debugInfo?.contains("/Users") == true || displayable.debugInfo == nil)
    }

    @Test
    func errorMessageUnder120Characters() {
        // Typical error that was too long before
        let error = OpenAIDashboardBrowserCookieImporter.ImportError.browserAccessDenied(
            details: "Safari cookie file exists but is not readable")

        let displayable = ErrorPresenter.present(error, context: .cookieExtraction(provider: "OpenAI"))

        #expect(displayable.statusBarText.count <= 120)
    }

    // MARK: - Action Hints

    @Test
    func permissionErrorHasSystemSettingsAction() {
        let error = OpenAIDashboardBrowserCookieImporter.ImportError.browserAccessDenied(
            details: "Safari cookie file exists but is not readable")

        #expect(error.actionHint == .openSystemSettings(pane: "Privacy & Security"))
    }

    @Test
    func noCookiesErrorHasBrowserAction() {
        let error = OpenAIDashboardBrowserCookieImporter.ImportError.noCookiesFound
        if case .openBrowser = error.actionHint {
            // Expected
        } else {
            Issue.record("Expected openBrowser action")
        }
    }

    @Test
    func networkErrorHasRetryAction() {
        let error = ClaudeWebAPIFetcher.FetchError.networkError(URLError(.notConnectedToInternet))
        #expect(error.actionHint == .retry)
    }
}

#else
// Stub for non-macOS platforms
@Suite
struct ErrorPresentationTests {
    @Test
    func stubTest() {
        // Tests only run on macOS
    }
}
#endif
