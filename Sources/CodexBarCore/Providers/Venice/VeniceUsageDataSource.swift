import Foundation

public enum VeniceUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case api
    case web

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .api: "API"
        case .web: "Web"
        }
    }
}
