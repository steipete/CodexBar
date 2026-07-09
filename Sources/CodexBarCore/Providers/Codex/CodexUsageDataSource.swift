import Foundation

public enum CodexUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case oauth
    case cli
    case custom

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .oauth: "OAuth API"
        case .cli: "CLI (RPC/PTY)"
        case .custom: "Custom API"
        }
    }

    public var sourceLabel: String {
        switch self {
        case .auto:
            "auto"
        case .oauth:
            "oauth"
        case .cli:
            "cli"
        case .custom:
            "custom"
        }
    }
}
