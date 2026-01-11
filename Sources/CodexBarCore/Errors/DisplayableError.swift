import Foundation

/// Context for error presentation - helps tailor messages to the operation
public enum ErrorContext: Sendable {
    case cookieExtraction(provider: String)
    case usageFetch(provider: String)
    case authentication(provider: String)
    case generic

    var providerName: String? {
        switch self {
        case let .cookieExtraction(provider),
             let .usageFetch(provider),
             let .authentication(provider):
            provider
        case .generic:
            nil
        }
    }
}

/// A user-friendly error ready for UI display
public struct DisplayableError: Sendable, Equatable {
    /// Brief title for the error (e.g., "Cookie Access Required")
    public let title: String

    /// User-friendly message (e.g., "Safari requires Full Disk Access")
    public let message: String

    /// Actionable suggestion (e.g., "Go to System Settings → Privacy...")
    public let suggestion: String?

    /// Optional action the user can take
    public let action: ErrorAction?

    /// Technical details for debugging (hidden from UI by default)
    public let debugInfo: String?

    public init(
        title: String,
        message: String,
        suggestion: String? = nil,
        action: ErrorAction? = nil,
        debugInfo: String? = nil)
    {
        self.title = title
        self.message = message
        self.suggestion = suggestion
        self.action = action
        self.debugInfo = debugInfo
    }

    /// Combined message suitable for status bar display
    public var statusBarText: String {
        if let suggestion {
            return "\(self.message). \(suggestion)"
        }
        return self.message
    }

    /// Short summary for compact displays
    public var compactText: String {
        self.message
    }
}

extension DisplayableError {
    /// Creates a generic error for unknown errors
    public static func generic(from error: Error, context: ErrorContext) -> DisplayableError {
        let providerPrefix = context.providerName.map { "\($0): " } ?? ""
        return DisplayableError(
            title: "Error",
            message: "\(providerPrefix)Something went wrong",
            suggestion: "Please try again later",
            action: .retry,
            debugInfo: error.localizedDescription)
    }

    /// Creates an error for permission denied scenarios
    public static func permissionDenied(
        browser: String,
        action: ErrorAction? = nil) -> DisplayableError
    {
        DisplayableError(
            title: "Permission Required",
            message: "\(browser) requires Full Disk Access",
            suggestion: "Go to System Settings → Privacy & Security → Full Disk Access → Enable for CodexBar",
            action: action ?? .openSystemSettings(pane: "Privacy & Security"))
    }

    /// Creates an error for not-logged-in scenarios
    public static func notLoggedIn(
        browser: String,
        provider: String,
        loginURL: URL? = nil) -> DisplayableError
    {
        DisplayableError(
            title: "Login Required",
            message: "\(browser) not logged in to \(provider)",
            suggestion: "Open \(browser) and log in to \(provider.lowercased()).ai",
            action: loginURL.map { .openBrowser(url: $0) })
    }

    /// Creates an error for expired sessions
    public static func sessionExpired(provider: String, loginURL: URL? = nil) -> DisplayableError {
        DisplayableError(
            title: "Session Expired",
            message: "\(provider) session has expired",
            suggestion: "Please log in again at \(provider.lowercased()).ai",
            action: loginURL.map { .openBrowser(url: $0) })
    }
}
