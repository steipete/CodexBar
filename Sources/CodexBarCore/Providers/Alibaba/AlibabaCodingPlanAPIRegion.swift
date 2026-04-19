import Foundation

public enum AlibabaCodingPlanAPIRegion: String, CaseIterable, Sendable {
    case international = "intl"
    case chinaMainland = "cn"

    private static let endpointPath = "data/api.json"

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

    public var dashboardURL: URL {
        switch self {
        case .international:
            URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/detail")!
        case .chinaMainland:
            URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")!
        }
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
            "MODELSTUDIO_ALIBABACLOUD"
        case .chinaMainland:
            "BAILIAN_ALIYUN"
        }
    }

    public var consoleRefererURL: URL {
        switch self {
        case .international:
            URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan")!
        case .chinaMainland:
            URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model")!
        }
    }

    public var quotaURL: URL {
        var components = URLComponents(string: self.gatewayBaseURLString)!
        components.path = "/" + Self.endpointPath
        components.queryItems = [
            URLQueryItem(
                name: "action",
                value: "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "product", value: "broadscope-bailian"),
            URLQueryItem(name: "api", value: "queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "currentRegionId", value: self.currentRegionID),
        ]
        return components.url!
    }

    public var consoleRPCBaseURLString: String {
        switch self {
        case .international:
            "https://bailian-singapore-cs.alibabacloud.com"
        case .chinaMainland:
            "https://bailian-cs.console.aliyun.com"
        }
    }

    public var consoleRPCURL: URL {
        var components = URLComponents(string: self.consoleRPCBaseURLString)!
        components.path = "/" + Self.endpointPath
        components.queryItems = [
            URLQueryItem(name: "action", value: self.consoleRPCAction),
            URLQueryItem(name: "product", value: self.consoleRPCProduct),
            URLQueryItem(name: "api", value: self.consoleQuotaAPIName),
            URLQueryItem(name: "_v", value: "undefined"),
        ]
        return components.url!
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

    public var consoleQuotaAPIName: String {
        "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"
    }

    public var commodityCode: String {
        switch self {
        case .international:
            "sfm_codingplan_public_intl"
        case .chinaMainland:
            "sfm_codingplan_public_cn"
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
}
