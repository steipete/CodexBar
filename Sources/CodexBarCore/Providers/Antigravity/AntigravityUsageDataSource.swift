import Foundation

public enum AntigravityUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case oauth
    case cli

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .oauth: "Google OAuth"
        case .cli: "Local IDE API"
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
        }
    }
}
