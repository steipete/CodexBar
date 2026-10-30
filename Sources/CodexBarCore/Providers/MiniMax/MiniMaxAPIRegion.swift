import Foundation

public enum MiniMaxAPIRegion: String, CaseIterable, Sendable {
    case global
    case chinaMainland = "cn"

    static let codingPlanPath = "user-center/payment/coding-plan"
    static let codingPlanQuery = "cycle_type=3"
    static let remainsPath = "v1/api/openplatform/coding_plan/remains"
    private static let tokenPlanRemainsPath = "v1/token_plan/remains"
    static let billingHistoryPath = "account/amount"

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

    var webBaseURLString: String {
        switch self {
        case .global: "https://www.minimax.io"
        case .chinaMainland: "https://www.minimaxi.com"
        }
    }

    public var codingPlanURL: URL {
        if self == .chinaMainland { return URL(string: "https://platform.minimax.cn/console/usage")! }
        var components = URLComponents(string: self.baseURLString)!
        components.path = "/" + Self.codingPlanPath
        components.query = Self.codingPlanQuery
        return components.url!
    }

    public var codingPlanRefererURL: URL {
        if self == .chinaMainland { return self.codingPlanURL }
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

    public var tokenPlanRemainsURL: URL {
        URL(string: self.apiBaseURLString)!.appendingPathComponent(Self.tokenPlanRemainsPath)
    }

    public var dashboardURL: URL {
        self.codingPlanURL
    }

    public func billingHistoryURL(page: Int, limit: Int) -> URL {
        var components = URLComponents(string: self.baseURLString)!
        components.path = "/" + Self.billingHistoryPath
        components.queryItems = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "aggregate", value: "false"),
        ]
        return components.url!
    }
}
