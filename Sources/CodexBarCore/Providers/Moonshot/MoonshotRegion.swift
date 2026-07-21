import Foundation

public enum MoonshotRegion: String, CaseIterable, Sendable {
    case international
    case china

    private static let balancePath = "v1/users/me/balance"

    public var displayName: String {
        switch self {
        case .international:
            "International · api.moonshot.ai"
        case .china:
            "China mainland · api.moonshot.cn"
        }
    }

    public var apiBaseURLString: String {
        switch self {
        case .international:
            "https://api.moonshot.ai"
        case .china:
            "https://api.moonshot.cn"
        }
    }

    /// Console where keys are issued for this region.
    public var consoleURL: URL {
        switch self {
        case .international:
            URL(string: "https://platform.moonshot.ai/console/account")!
        case .china:
            // China open platform is also branded as platform.kimi.com.
            URL(string: "https://platform.kimi.com/console/account")!
        }
    }

    public var balanceURL: URL {
        URL(string: self.apiBaseURLString)!.appendingPathComponent(Self.balancePath)
    }
}
