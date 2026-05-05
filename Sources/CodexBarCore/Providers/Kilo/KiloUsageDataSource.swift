import Foundation

public enum KiloUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case api
    case cli

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .api: "API"
        case .cli: "CLI"
        }
    }

    public var sourceLabel: String {
        switch self {
        case .auto:
            "auto"
        case .api:
            "api"
        case .cli:
            "cli"
        }
    }
}
