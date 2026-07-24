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

    public var personalDashboardURL: URL {
        switch self {
        case .international:
            URL(
                string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/" +
                    "?tab=plan#/efm/subscription/token-plan/personal")!
        case .chinaMainland:
            URL(
                string: "https://bailian.console.aliyun.com/cn-beijing" +
                    "?tab=plan#/efm/subscription/token-plan/personal")!
        }
    }

    public var consoleRPCBaseURLString: String {
        switch self {
        case .international:
            "https://bailian-singapore-cs.alibabacloud.com"
        case .chinaMainland:
            "https://bailian-cs.console.aliyun.com"
        }
    }

    public var consoleRPCAction: String {
        switch self {
        case .international:
            "IntlBroadScopeAspnGateway"
        case .chinaMainland:
            "BroadScopeAspnGateway"
        }
    }

    public var consoleRPCProduct: String {
        "sfm_bailian"
    }

    public var rateLimitAPIName: String {
        "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    }

    public var rateLimitURL: URL {
        var components = URLComponents(string: self.consoleRPCBaseURLString)!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: self.consoleRPCAction),
            URLQueryItem(name: "product", value: self.consoleRPCProduct),
            URLQueryItem(name: "api", value: self.rateLimitAPIName),
            URLQueryItem(name: "_v", value: "undefined"),
        ]
        return components.url!
    }

    public var consoleDomain: String {
        switch self {
        case .international:
            "modelstudio.console.alibabacloud.com"
        case .chinaMainland:
            "bailian.console.aliyun.com"
        }
    }

    public var consoleSite: String {
        switch self {
        case .international:
            // This is Alibaba's live console contract, including its historical spelling.
            "MODELSTUDIO_ALBABACLOUD"
        case .chinaMainland:
            "BAILIAN_ALIYUN"
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
