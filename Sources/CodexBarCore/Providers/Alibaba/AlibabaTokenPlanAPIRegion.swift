import Foundation

public enum AlibabaTokenPlanAPIRegion: String, CaseIterable, Sendable {
    case international = "intl"
    case chinaMainland = "cn"

    public var displayName: String {
        switch self {
        case .international:
            "International (modelstudio.console.alibabacloud.com)"
        case .chinaMainland:
            "China mainland (bailian.console.aliyun.com)"
        }
    }

    public var gatewayBaseURLString: String {
        switch self {
        case .international:
            "https://modelstudio.console.alibabacloud.com"
        case .chinaMainland:
            "https://bailian.console.aliyun.com"
        }
    }

    public var dashboardOriginURLString: String {
        self.gatewayBaseURLString
    }

    public var dashboardURL: URL {
        switch self {
        case .international:
            URL(
                string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=plan#/efm/subscription/token-plan")!
        case .chinaMainland:
            URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan")!
        }
    }

    public var currentRegionID: String {
        switch self {
        case .international:
            "ap-southeast-1"
        case .chinaMainland:
            "cn-beijing"
        }
    }

    public var tokenPlanProductCode: String {
        switch self {
        case .international:
            "sfm_tokenplanteams_dp_intl"
        case .chinaMainland:
            "sfm_tokenplanteams_dp_cn"
        }
    }

    public var cookieCacheScope: CookieHeaderCache.Scope {
        .providerVariant("alibaba-token-plan.\(self.rawValue)")
    }
}
