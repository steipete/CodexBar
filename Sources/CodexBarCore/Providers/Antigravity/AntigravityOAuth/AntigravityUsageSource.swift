import Foundation

public enum AntigravityUsageSource: String, CaseIterable, Sendable, Codable {
    case auto
    case authorized
    case local

    public init?(rawValue: String) {
        switch rawValue {
        case "auto":
            self = .auto
        case "authorized":
            self = .authorized
        case "local", "cli":
            self = .local
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .auto:
            "Auto"
        case .authorized:
            "OAuth"
        case .local:
            "Local Server"
        }
    }

    public var description: String {
        switch self {
        case .auto:
            "Try OAuth/manual tokens first, fallback to local server"
        case .authorized:
            "Use OAuth account or manual tokens only"
        case .local:
            "Use local Antigravity language server only"
        }
    }
}
