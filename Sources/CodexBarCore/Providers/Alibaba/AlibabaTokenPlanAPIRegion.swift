import Foundation

public enum AlibabaTokenPlanAPIRegion: String, CaseIterable, Sendable {
    case international = "intl"
    case chinaMainland = "cn"
    case internationalPersonal = "intl-personal"
    case chinaMainlandPersonal = "cn-personal"

    public var displayName: String {
        switch self {
        case .international:
            "International — Team (modelstudio.console.alibabacloud.com)"
        case .chinaMainland:
            "China mainland — Team (bailian.console.aliyun.com)"
        case .internationalPersonal:
            "International — Personal/Solo (modelstudio.console.alibabacloud.com)"
        case .chinaMainlandPersonal:
            "China mainland — Personal/Solo (bailian.console.aliyun.com)"
        }
    }

    public var gatewayBaseURLString: String {
        switch self {
        case .international, .internationalPersonal:
            "https://modelstudio.console.alibabacloud.com"
        case .chinaMainland, .chinaMainlandPersonal:
            "https://bailian.console.aliyun.com"
        }
    }

    public var quotaBaseURLString: String {
        switch self {
        case .international:
            self.gatewayBaseURLString
        case .chinaMainland:
            self.gatewayBaseURLString
        case .internationalPersonal:
            "https://bailian-singapore-cs.alibabacloud.com"
        case .chinaMainlandPersonal:
            "https://bailian-cs.console.aliyun.com"
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
        case .internationalPersonal:
            URL(
                string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/" +
                    "?tab=plan#/efm/subscription/token-plan/personal")!
        case .chinaMainlandPersonal:
            URL(
                string: "https://bailian.console.aliyun.com/cn-beijing" +
                    "?tab=plan#/efm/subscription/token-plan/personal")!
        }
    }

    public var currentRegionID: String {
        switch self {
        case .international, .internationalPersonal:
            "ap-southeast-1"
        case .chinaMainland, .chinaMainlandPersonal:
            "cn-beijing"
        }
    }

    public var cliConsoleSite: String {
        switch self {
        case .international, .internationalPersonal:
            "international"
        case .chinaMainland, .chinaMainlandPersonal:
            "domestic"
        }
    }

    public var tokenPlanProductCode: String {
        switch self {
        case .international:
            "sfm_tokenplanteams_dp_intl"
        case .chinaMainland:
            "sfm_tokenplanteams_dp_cn"
        case .internationalPersonal:
            "sfm_tokenplansolo_public_intl"
        case .chinaMainlandPersonal:
            "sfm_tokenplansolo_public_cn"
        }
    }

    public var usesPersonalTokenPlanAPI: Bool {
        switch self {
        case .international, .chinaMainland:
            false
        case .internationalPersonal, .chinaMainlandPersonal:
            true
        }
    }

    public var personalAPIAction: String {
        switch self {
        case .international, .internationalPersonal:
            "IntlBroadScopeAspnGateway"
        case .chinaMainland, .chinaMainlandPersonal:
            "BroadScopeAspnGateway"
        }
    }

    public var personalConsoleSite: String {
        switch self {
        case .international, .internationalPersonal:
            // This is Alibaba's live console contract, including its historical spelling.
            "MODELSTUDIO_ALBABACLOUD"
        case .chinaMainland, .chinaMainlandPersonal:
            "BAILIAN_ALIYUN"
        }
    }

    public var cookieCacheScope: CookieHeaderCache.Scope {
        .providerVariant("alibaba-token-plan.\(self.rawValue)")
    }
}
