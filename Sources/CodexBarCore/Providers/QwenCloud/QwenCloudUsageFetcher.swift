import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum QwenCloudUsageError: LocalizedError, Equatable {
    case loginRequired
    case invalidCredentials
    case apiError(String)
    case networkError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .loginRequired:
            "Qwen Cloud login required. Sign in to Qwen Cloud in your browser and try again."
        case .invalidCredentials:
            "Qwen Cloud rejected the stored session. Re-import or re-paste your Cookie header."
        case let .apiError(message):
            "Qwen Cloud usage API error: \(message)"
        case let .networkError(message):
            "Qwen Cloud network error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Qwen Cloud usage: \(message)"
        }
    }
}

/// Orchestrator for Qwen Cloud token-plan usage fetches.
///
/// Owns: dashboard / API URL resolution, host-override normalization, and
/// the sec_token -> three API calls -> snapshot flow. Request construction
/// lives in `QwenCloudTokenPlanAPIClient`; response parsing lives in
/// `QwenCloudUsageParser`.
public struct QwenCloudUsageFetcher: Sendable {
    public static let gatewayBaseURLString = "https://home.qwencloud.com"
    static let dataGatewayBaseURLString = "https://cs-data.qwencloud.com"
    /// Qwen Cloud international "token plan (individual)" product code.
    static let productCode = "sfm_tokenplansolo_public_intl"
    static let consoleProduct = "sfm_bailian"
    static let consoleAction = "IntlBroadScopeAspnGateway"
    static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    static let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    static let quotaConfigAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/quota-config"
    static let region = "ap-southeast-1"
    static let language = "en-US"

    static let log = CodexBarLog.logger("qwen-cloud")

    public static var dashboardURL: URL {
        self.dashboardURL(environment: ProcessInfo.processInfo.environment)
    }

    public static func dashboardURL(environment: [String: String]) -> URL {
        if let override = QwenCloudSettingsReader.hostOverride(environment: environment) {
            let base = override.hasSuffix("/") ? String(override.dropLast()) : override
            if let url = URL(string: "\(base)/billing/subscription/token-plan-individual") {
                return url
            }
        }
        return URL(string: "\(self.gatewayBaseURLString)/billing/subscription/token-plan-individual")!
    }

    public static var defaultQuotaURL: URL {
        self.defaultQuotaURL(environment: ProcessInfo.processInfo.environment)
    }

    public static func defaultQuotaURL(environment: [String: String]) -> URL {
        self.defaultAPIURL(api: self.usageAPI, environment: environment)
    }

    public static func resolveQuotaURL(environment: [String: String]) -> URL {
        self.resolveAPIURL(api: self.usageAPI, environment: environment)
    }

    static func resolveAPIURL(api: String, environment: [String: String]) -> URL {
        if let override = QwenCloudSettingsReader.quotaURL(environment: environment) {
            return override
        }
        return self.defaultAPIURL(api: api, environment: environment)
    }

    fileprivate static func defaultAPIURL(api: String, environment: [String: String]) -> URL {
        let base = self.dataGatewayHostBase(environment: environment)
        var components = URLComponents(string: "\(base)/data/api.json")!
        components.queryItems = [
            URLQueryItem(name: "action", value: self.consoleAction),
            URLQueryItem(name: "product", value: self.consoleProduct),
            URLQueryItem(name: "api", value: api),
            URLQueryItem(name: "_v", value: "undefined"),
        ]
        return components.url!
    }

    static func gatewayHostBase(environment: [String: String]) -> String {
        if let override = QwenCloudSettingsReader.hostOverride(environment: environment) {
            return override.hasSuffix("/") ? String(override.dropLast()) : override
        }
        return self.gatewayBaseURLString
    }

    fileprivate static func dataGatewayHostBase(environment: [String: String]) -> String {
        if let override = QwenCloudSettingsReader.hostOverride(environment: environment) {
            return override.hasSuffix("/") ? String(override.dropLast()) : override
        }
        return self.dataGatewayBaseURLString
    }

    private static let secTokenResolver = OneConsoleSECTokenResolver(
        configuration: OneConsoleSECTokenResolver.Configuration(
            dashboardURL: { QwenCloudUsageFetcher.dashboardURL(environment: $0) },
            userInfoPath: "/tool/user/info.json",
            isLoginPage: QwenCloudUsageFetcher.looksLikeLoginPage))

    public static func fetchUsage(
        apiCookieHeader rawCookieHeader: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        transport: (any ProviderHTTPTransport)? = nil) async throws -> QwenCloudUsageSnapshot
    {
        try await self.fetchUsage(
            apiCookieHeader: rawCookieHeader,
            dashboardCookieHeader: rawCookieHeader,
            environment: environment,
            now: now,
            transport: transport)
    }

    public static func fetchUsage(
        apiCookieHeader: String,
        dashboardCookieHeader: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        transport: (any ProviderHTTPTransport)? = nil) async throws -> QwenCloudUsageSnapshot
    {
        let normalizedAPI = CookieHeaderNormalizer.normalize(apiCookieHeader)
        let normalizedDashboard = CookieHeaderNormalizer.normalize(dashboardCookieHeader) ?? normalizedAPI
        guard let cookieHeader = normalizedAPI, !cookieHeader.isEmpty else {
            throw QwenCloudSettingsError.invalidCookie
        }
        let dashboardHeader = normalizedDashboard ?? cookieHeader

        let usageURL = self.resolveQuotaURL(environment: environment)
        guard let host = usageURL.host else {
            throw QwenCloudUsageError.networkError("Invalid quota URL")
        }
        let dashboardURL = self.dashboardURL(environment: environment)
        guard dashboardURL.host != nil else {
            throw QwenCloudUsageError.networkError("Invalid dashboard URL")
        }
        let activeTransport: any ProviderHTTPTransport = transport ?? QwenCloudHTTPTransport(
            routing: OneConsoleCookieRouting(
                apiURL: usageURL,
                dashboardURL: dashboardURL,
                apiCookieHeader: cookieHeader,
                dashboardCookieHeader: dashboardHeader))
        let resolved: OneConsoleSECTokenResolver.Resolved
        do {
            resolved = try await self.secTokenResolver.resolve(
                cookieHeader: dashboardHeader,
                environment: environment,
                transport: activeTransport)
        } catch OneConsoleSECTokenError.notFound {
            throw QwenCloudUsageError.loginRequired
        } catch {
            throw QwenCloudUsageError.networkError(error.localizedDescription)
        }
        Self.log.info("Resolved Qwen Cloud sec_token from \(resolved.source.rawValue)")

        let client = QwenCloudTokenPlanAPIClient(transport: activeTransport)
        let context = QwenCloudTokenPlanAPIClient.Context(
            secToken: resolved.value,
            secTokenSource: resolved.source.rawValue,
            environment: environment,
            apiCookieHeader: cookieHeader,
            dashboardURL: dashboardURL)

        let usageData: Data
        do {
            usageData = try await client.fetch(
                api: self.usageAPI,
                dataParameters: [:],
                context: context)
        } catch let error as QwenCloudUsageError {
            throw error
        } catch {
            throw QwenCloudUsageError.networkError(error.localizedDescription)
        }

        let subscriptionData = await client.fetchOptional(
            api: self.subscriptionAPI,
            dataParameters: ["commodityCode": self.productCode],
            context: context)
        let quotaConfigData = await client.fetchOptional(
            api: self.quotaConfigAPI,
            dataParameters: [:],
            context: context)

        do {
            return try QwenCloudUsageParser.parse(
                from: usageData,
                subscriptionData: subscriptionData,
                quotaConfigData: quotaConfigData,
                now: now)
        } catch let error as QwenCloudUsageError {
            let contentType = Self.contentType(of: usageData)
            let bodyPreview = String(data: usageData.prefix(200), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? "<\(usageData.count) bytes>"
            Self.log.warning(
                "Qwen Cloud usage parse failed",
                metadata: [
                    "apiHost": host,
                    "status": "200",
                    "contentType": contentType ?? "unknown",
                    "bodyPreview": bodyPreview,
                    "error": "\(error)",
                ])
            throw error
        }
    }

    private static func contentType(of data: Data) -> String? {
        let head = data.prefix(64)
        if head.contains(0x7B) || head.contains(0x5B) {
            return "application/json"
        }
        let prefix = String(data: head, encoding: .utf8)?.lowercased() ?? ""
        if prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") {
            return "text/html"
        }
        return nil
    }

    private static func looksLikeLoginPage(_ html: String) -> Bool {
        let lowered = html.lowercased()
        return lowered.contains("passport.alibabacloud.com") ||
            lowered.contains("signin.aliyun.com") ||
            lowered.contains("account.alibabacloud.com/login") ||
            lowered.contains("login.qwencloud.com") ||
            (lowered.contains("login") && lowered.contains("password") && lowered.contains("sign in"))
    }

    public static func parseUsageSnapshot(
        from data: Data,
        now: Date = Date()) throws -> QwenCloudUsageSnapshot
    {
        try QwenCloudUsageParser.parseUsageSnapshot(from: data, now: now)
    }
}
