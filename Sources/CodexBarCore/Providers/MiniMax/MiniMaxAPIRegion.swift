import Foundation

public enum MiniMaxAPIRegion: String, CaseIterable, Sendable {
    case global
    case chinaMainland = "cn"

    private static let codingPlanPath = "user-center/payment/coding-plan"
    private static let codingPlanQuery = "cycle_type=3"
    private static let remainsPath = "v1/api/openplatform/coding_plan/remains"

    public var displayName: String {
        switch self {
        case .global:
            "Global (platform.minimax.io)"
        case .chinaMainland:
            "China mainland (platform.minimaxi.com)"
        }
    }

    public var baseURLString: String {
        switch self {
        case .global:
            "https://platform.minimax.io"
        case .chinaMainland:
            "https://platform.minimaxi.com"
        }
    }

    public var apiBaseURLString: String {
        switch self {
        case .global:
            "https://api.minimax.io"
        case .chinaMainland:
            "https://api.minimaxi.com"
        }
    }

    public var codingPlanURL: URL {
        var components = URLComponents(string: self.baseURLString)!
        components.path = "/" + Self.codingPlanPath
        components.query = Self.codingPlanQuery
        return components.url!
    }

    public var codingPlanRefererURL: URL {
        var components = URLComponents(string: self.baseURLString)!
        components.path = "/" + Self.codingPlanPath
        return components.url!
    }

    public var remainsURL: URL {
        URL(string: self.baseURLString)!.appendingPathComponent(Self.remainsPath)
    }

    public var apiRemainsURL: URL {
        URL(string: self.apiBaseURLString)!.appendingPathComponent(Self.remainsPath)
    }
}
