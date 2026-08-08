import Foundation

public enum ClaudeUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case api
    case oauth
    case web
    case cli
    /// Live windows forwarded by a user-configured Claude statusLine command. Composes with the polled
    /// sources inside Auto and is never offered as a standalone selection — see `isUserSelectable`.
    case statusline

    /// The statusLine feed is silent whenever the user is not running Claude Code, so pinning it would strand
    /// the card. It only ever participates as an additive step in the Auto order (owner ruling, #2733).
    public var isUserSelectable: Bool {
        self != .statusline
    }

    public static var userSelectableCases: [ClaudeUsageDataSource] {
        self.allCases.filter(\.isUserSelectable)
    }

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .api: "API (Admin key)"
        case .oauth: "OAuth API"
        case .web: "Web API (cookies)"
        case .cli: "CLI (PTY)"
        case .statusline: "Claude statusLine feed"
        }
    }

    public var sourceLabel: String {
        switch self {
        case .auto:
            "auto"
        case .api:
            "api"
        case .oauth:
            "oauth"
        case .web:
            "web"
        case .cli:
            "cli"
        case .statusline:
            "statusline"
        }
    }
}
