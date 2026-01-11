import Foundation

/// Actions that can be suggested to users to resolve errors
public enum ErrorAction: Sendable, Equatable {
    /// Open macOS System Settings to a specific pane
    case openSystemSettings(pane: String)
    /// Open a URL in the default browser
    case openBrowser(url: URL)
    /// Retry the failed operation
    case retry
    /// Open app preferences to a specific tab
    case openPreferences(tab: String)

    /// Human-readable label for action buttons
    public var buttonLabel: String {
        switch self {
        case .openSystemSettings:
            "Open System Settings"
        case .openBrowser:
            "Learn More"
        case .retry:
            "Try Again"
        case .openPreferences:
            "Open Preferences"
        }
    }
}

/// Protocol for errors that can be presented to users with actionable guidance
public protocol UserFacingError: LocalizedError, Sendable {
    /// Brief user-friendly message (1 sentence, no jargon, no file paths)
    var userMessage: String { get }

    /// Actionable guidance for resolving the error
    var recoverySuggestion: String? { get }

    /// Optional action that can help resolve the error
    var actionHint: ErrorAction? { get }

    /// Technical details (hidden from UI, available for logs/debugging)
    var technicalDetails: String? { get }
}

/// Default implementations for optional properties
extension UserFacingError {
    public var recoverySuggestion: String? { nil }
    public var actionHint: ErrorAction? { nil }
    public var technicalDetails: String? { nil }

    /// Provides LocalizedError.errorDescription from userMessage
    public var errorDescription: String? { self.userMessage }
}
