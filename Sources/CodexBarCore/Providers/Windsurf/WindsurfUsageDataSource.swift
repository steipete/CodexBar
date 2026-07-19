import Foundation

public enum WindsurfUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case web
    case cli

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .web: "Web API (IndexedDB)"
        case .cli: "Local (SQLite cache)"
        }
    }

    public var sourceLabel: String {
        switch self {
        case .auto: "auto"
        case .web: "web"
        case .cli: "cli"
        }
    }
}
