import Foundation

public enum AlibabaTokenPlanAPIRegion: String, CaseIterable, Sendable {
    case international = "intl"
    case chinaMainland = "cn"
    case qwenCloudPersonal = "qwen"

    public var displayName: String {
        switch self {
        case .international:
            "International (modelstudio.console.alibabacloud.com)"
        case .chinaMainland:
            "China mainland (bailian.console.aliyun.com)"
        case .qwenCloudPersonal:
            "Qwen Cloud personal (home.qwencloud.com)"
        }
    }

    public var gatewayBaseURLString: String {
        switch self {
        case .international:
            "https://modelstudio.console.alibabacloud.com"
        case .chinaMainland:
            "https://bailian.console.aliyun.com"
        case .qwenCloudPersonal:
            "https://home.qwencloud.com"
        }
    }

    /// Qwen Cloud serves the console shell and the data gateway from different hosts; the
    /// other regions post back to the console host itself.
    public var quotaAPIBaseURLString: String {
        switch self {
        case .international, .chinaMainland:
            self.gatewayBaseURLString
        case .qwenCloudPersonal:
            "https://cs-data.qwencloud.com"
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
        case .qwenCloudPersonal:
            URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")!
        }
    }

    public var currentRegionID: String {
        switch self {
        case .international, .qwenCloudPersonal:
            "ap-southeast-1"
        case .chinaMainland:
            "cn-beijing"
        }
    }

    /// Team-edition subscription summaries are keyed by commodity code. The personal plan
    /// uses a REST-style gateway that takes no product code, so this is nil there.
    public var tokenPlanProductCode: String? {
        switch self {
        case .international:
            "sfm_tokenplanteams_dp_intl"
        case .chinaMainland:
            "sfm_tokenplanteams_dp_cn"
        case .qwenCloudPersonal:
            nil
        }
    }

    /// The personal plan reports rolling 5-hour/weekly windows instead of a credit pool,
    /// which changes the gateway payload, the response schema, and the rendered windows.
    public var usesPersonalTokenPlanAPI: Bool {
        self == .qwenCloudPersonal
    }

    /// Qwen Cloud logs in under its own domain with its own ticket cookie name
    /// (`login_qwencloud_ticket`), neither of which the shared Alibaba browser importer
    /// recognises, so this region requires a manually supplied cookie header.
    public var supportsBrowserCookieImport: Bool {
        self != .qwenCloudPersonal
    }

    public var cookieCacheScope: CookieHeaderCache.Scope {
        .providerVariant("alibaba-token-plan.\(self.rawValue)")
    }
}
