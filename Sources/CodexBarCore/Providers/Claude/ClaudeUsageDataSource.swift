import Foundation

public enum ClaudeUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case oauth
    case web
    case cli

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .oauth: "OAuth API"
        case .web: "Web API (cookies)"
        case .cli: "CLI (PTY)"
        }
    }

    public var sourceLabel: String {
        switch self {
        case .auto:
            "auto"
        case .oauth:
            "oauth"
        case .web:
            "web"
        case .cli:
            "cli"
        }
    }
}
