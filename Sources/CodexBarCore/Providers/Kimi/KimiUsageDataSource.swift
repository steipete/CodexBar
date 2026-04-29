import Foundation

public enum KimiUsageDataSource: String, CaseIterable, Identifiable, Sendable {
    case auto
    case oauth
    case api

    public var id: String {
        self.rawValue
    }

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .oauth: "CLI OAuth"
        case .api: "API Key"
        }
    }
}
