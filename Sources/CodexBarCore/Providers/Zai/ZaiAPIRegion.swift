import Foundation

public enum ZaiAPIRegion: String, CaseIterable, Sendable {
    case global
    case bigmodelCN = "bigmodel-cn"

    private static let quotaPath = "api/monitor/usage/quota/limit"
    private static let modelUsagePath = "api/monitor/usage/model-usage"

    public var displayName: String {
        switch self {
        case .global:
            "Global (api.z.ai)"
        case .bigmodelCN:
            "BigModel CN (open.bigmodel.cn)"
        }
    }

    public var baseURLString: String {
        switch self {
        case .global:
            "https://api.z.ai"
        case .bigmodelCN:
            "https://open.bigmodel.cn"
        }
    }

    public var quotaLimitURL: URL {
        URL(string: self.baseURLString)!.appendingPathComponent(Self.quotaPath)
    }

    public var modelUsageURL: URL {
        URL(string: self.baseURLString)!.appendingPathComponent(Self.modelUsagePath)
    }

    public var dashboardURL: URL {
        switch self {
        case .global:
            URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")!
        case .bigmodelCN:
            URL(string: "https://bigmodel.cn/coding-plan/personal/usage")!
        }
    }

    public var teamDashboardURL: URL {
        switch self {
        case .global:
            self.dashboardURL
        case .bigmodelCN:
            URL(string: "https://bigmodel.cn/coding-plan/team/usage-stats")!
        }
    }
}

public enum ZaiEndpointRouter {
    private static let quotaPath = "api/monitor/usage/quota/limit"
    private static let modelUsagePath = "api/monitor/usage/model-usage"

    public static func resolveQuotaURL(
        region: ZaiAPIRegion,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let override = ZaiSettingsReader.quotaURL(environment: environment) {
            return override
        }
        if let host = ZaiSettingsReader.apiHost(environment: environment),
           let url = self.endpointURL(baseURLString: host, path: self.quotaPath)
        {
            return url
        }
        return region.quotaLimitURL
    }

    public static func resolveModelUsageURL(
        region: ZaiAPIRegion,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL
    {
        if let host = ZaiSettingsReader.apiHost(environment: environment),
           let url = self.endpointURL(baseURLString: host, path: self.modelUsagePath)
        {
            return url
        }
        return region.modelUsageURL
    }

    public static func resolveDashboardURL(
        region: ZaiAPIRegion,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        usageScope: ZaiUsageScope = .personal) -> URL
    {
        let quotaHost = self.resolveQuotaURL(region: region, environment: environment).host?.lowercased()
        if quotaHost == ZaiAPIRegion.global.quotaLimitURL.host?.lowercased() {
            return usageScope == .team ? ZaiAPIRegion.global.teamDashboardURL : ZaiAPIRegion.global.dashboardURL
        }
        if quotaHost == ZaiAPIRegion.bigmodelCN.quotaLimitURL.host?.lowercased() {
            return usageScope == .team ? ZaiAPIRegion.bigmodelCN.teamDashboardURL : ZaiAPIRegion.bigmodelCN.dashboardURL
        }
        return usageScope == .team ? region.teamDashboardURL : region.dashboardURL
    }

    private static func endpointURL(baseURLString: String, path: String) -> URL? {
        guard let cleaned = ZaiSettingsReader.cleaned(baseURLString),
              let url = ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: cleaned)
        else { return nil }
        if url.path.isEmpty || url.path == "/" {
            return url.appendingPathComponent(path)
        }
        return url
    }
}
