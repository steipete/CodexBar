import Foundation

public enum ClaudeUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case api
    case oauth
    case web
    case cli

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
        }
    }
}
