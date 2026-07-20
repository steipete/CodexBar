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

public struct QwenCloudUsageFetcher: Sendable {
    public static let gatewayBaseURLString = "https://home.qwencloud.com"
    /// Qwen Cloud international "token plan (individual)" product code.
    static let productCode = "sfm_tokenplansolo_public_intl"
    static let region = "ap-southeast-1"
    static let language = "en-US"

    private static let log = CodexBarLog.logger("qwen-cloud")

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
        let base = self.gatewayHostBase(environment: environment)
        return URL(string: "\(base)/data/api.json?action=GetSubscriptionSummary&product=BssOpenAPI-V3&_tag=")!
    }

    public static func resolveQuotaURL(environment: [String: String]) -> URL {
        if let override = QwenCloudSettingsReader.quotaURL(environment: environment) {
            return override
        }
        return self.defaultQuotaURL(environment: environment)
    }

    private static func gatewayHostBase(environment: [String: String]) -> String {
        if let override = QwenCloudSettingsReader.hostOverride(environment: environment) {
            return override.hasSuffix("/") ? String(override.dropLast()) : override
        }
        return self.gatewayBaseURLString
    }

    public static func fetchUsage(
        apiCookieHeader rawCookieHeader: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        session: URLSession = .shared) async throws -> QwenCloudUsageSnapshot
    {
        try await self.fetchUsage(
            apiCookieHeader: rawCookieHeader,
            dashboardCookieHeader: rawCookieHeader,
            environment: environment,
            now: now,
            session: session)
    }

    public static func fetchUsage(
        apiCookieHeader: String,
        dashboardCookieHeader: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        session: URLSession = .shared) async throws -> QwenCloudUsageSnapshot
    {
        let normalizedAPI = CookieHeaderNormalizer.normalize(apiCookieHeader)
        let normalizedDashboard = CookieHeaderNormalizer.normalize(dashboardCookieHeader) ?? normalizedAPI
        guard let cookieHeader = normalizedAPI, !cookieHeader.isEmpty else {
            throw QwenCloudSettingsError.invalidCookie
        }

        let quotaURL = self.resolveQuotaURL(environment: environment)
        guard let host = quotaURL.host else { throw QwenCloudUsageError.networkError("Invalid quota URL") }
        let apiCookieNames = self.cookieNames(from: cookieHeader)
        let secToken = try await self.resolveSECSessionToken(
            cookieHeader: normalizedDashboard ?? cookieHeader,
            environment: environment,
            session: session)
        let secTokenValue = secToken.value

        var request = URLRequest(url: quotaURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(self.gatewayHostBase(environment: environment), forHTTPHeaderField: "Origin")
        request.setValue(self.dashboardURL(environment: environment).absoluteString, forHTTPHeaderField: "Referer")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "product", value: "BssOpenAPI-V3"),
            URLQueryItem(name: "action", value: "GetSubscriptionSummary"),
            URLQueryItem(name: "sec_token", value: secTokenValue),
            URLQueryItem(name: "region", value: self.region),
            URLQueryItem(name: "language", value: self.language),
            URLQueryItem(
                name: "params",
                value: #"{"productCode":"\#(self.productCode)"}"#),
        ]
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)

        Self.log.info(
            "Fetching Qwen Cloud usage",
            metadata: [
                "apiHost": host,
                "apiCookieNames": apiCookieNames.joined(separator: ","),
                "hasCSRF": self.cookieNames(from: cookieHeader).contains("XSRF-TOKEN") ? "1" : "0",
                "secTokenSource": secToken.sourceLabel,
            ])

        let data: Data
        do {
            data = try await self.fetchData(
                session: session,
                request: request,
                cookieHeader: cookieHeader,
                dashboardCookieHeader: normalizedDashboard ?? cookieHeader)
        } catch let error as QwenCloudUsageError {
            throw error
        } catch {
            throw QwenCloudUsageError.networkError(error.localizedDescription)
        }
        do {
            return try self.parseUsageSnapshot(from: data, now: now)
        } catch let error as QwenCloudUsageError {
            let contentType = self.contentType(of: data)
            let bodyPreview = String(data: data.prefix(200), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? "<\(data.count) bytes>"
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

    static func parseUsageSnapshot(from data: Data, now: Date = Date()) throws -> QwenCloudUsageSnapshot {
        do {
            let alibaba = try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: data, now: now)
            return QwenCloudUsageSnapshot(alibabaSnapshot: alibaba)
        } catch let error as AlibabaTokenPlanUsageError {
            throw Self.map(error)
        }
    }

    private static func map(_ error: AlibabaTokenPlanUsageError) -> QwenCloudUsageError {
        switch error {
        case .loginRequired: .loginRequired
        case .invalidCredentials: .invalidCredentials
        case let .apiError(message): .apiError(message)
        case let .networkError(message): .networkError(message)
        case let .parseFailed(message): .parseFailed(message)
        }
    }

    // MARK: - SEC session token

    private static func resolveSECSessionToken(
        cookieHeader: String,
        environment: [String: String],
        session: URLSession) async throws -> (value: String, sourceLabel: String)
    {
        let dashboardURL = self.dashboardURL(environment: environment)

        // The Qwen Cloud one-console injects a user-specific `sec_token` into the
        // dashboard HTML (window.ALIYUN_CONSOLE_CONFIG / `sec_token = "..."`). Fetch the
        // billing page with the session cookie and extract it.
        if let htmlToken = try? await self.fetchSECSessionTokenFromDashboard(
            cookieHeader: cookieHeader,
            dashboardURL: dashboardURL,
            session: session)
        {
            return (htmlToken, "dashboard-html")
        }

        // Some console sessions also expose a `sec_token` cookie scoped to the console
        // host; prefer it when present.
        if let cookieToken = self.secTokenCookieValue(from: cookieHeader, host: dashboardURL.host) {
            return (cookieToken, "cookie")
        }

        // Final fallback: the one-console user-info endpoint returns the active token.
        if let userInfoToken = try? await self.fetchSECSessionTokenFromUserInfo(
            cookieHeader: cookieHeader,
            dashboardURL: dashboardURL,
            session: session)
        {
            return (userInfoToken, "user-info")
        }

        throw QwenCloudUsageError.loginRequired
    }

    private static func fetchSECSessionTokenFromDashboard(
        cookieHeader: String,
        dashboardURL: URL,
        session: URLSession) async throws -> String
    {
        var request = URLRequest(url: dashboardURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let data = try await self.fetchData(
            session: session,
            request: request,
            cookieHeader: cookieHeader,
            dashboardCookieHeader: cookieHeader)

        guard let html = String(data: data, encoding: .utf8) else {
            throw QwenCloudUsageError.loginRequired
        }
        if self.looksLikeLoginPage(html) {
            throw QwenCloudUsageError.loginRequired
        }
        if let token = self.extractSECSessionToken(from: html) {
            Self.log.info("Resolved Qwen Cloud sec_token from dashboard HTML")
            return token
        }
        throw QwenCloudUsageError.loginRequired
    }

    private static func fetchSECSessionTokenFromUserInfo(
        cookieHeader: String,
        dashboardURL: URL,
        session: URLSession) async throws -> String
    {
        let host = dashboardURL.host ?? "home.qwencloud.com"
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        if let port = dashboardURL.port {
            components.port = port
        }
        components.path = "/tool/user/info.json"
        guard let url = components.url else {
            throw QwenCloudUsageError.loginRequired
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let data = try await self.fetchData(
            session: session,
            request: request,
            cookieHeader: cookieHeader,
            dashboardCookieHeader: cookieHeader)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QwenCloudUsageError.loginRequired
        }
        let dataDict: [String: Any]? = {
            for key in ["data", "Data"] {
                if let value = json[key] as? [String: Any] {
                    return value
                }
            }
            return nil
        }()
        guard let dataDict else {
            throw QwenCloudUsageError.loginRequired
        }

        for key in ["secToken", "sec_token", "csrfToken", "token"] {
            if let value = dataDict[key] as? String, !value.isEmpty {
                Self.log.info("Resolved Qwen Cloud sec_token from user info")
                return value
            }
        }
        throw QwenCloudUsageError.loginRequired
    }

    private static func extractSECSessionToken(from html: String) -> String? {
        let patterns = [
            #""secToken"\s*:\s*"([^"]+)""#,
            #""sec_token"\s*:\s*"([^"]+)""#,
            #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"csrfToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
        ]
        for pattern in patterns {
            if let token = self.matchFirstGroup(pattern: pattern, in: html), !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private static func matchFirstGroup(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        let value = text[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }

    private static func secTokenCookieValue(from cookieHeader: String, host: String?) -> String? {
        var fallback: String?
        for pair in CookieHeaderNormalizer.pairs(from: cookieHeader) {
            guard pair.name.lowercased() == "sec_token", !pair.value.isEmpty else { continue }
            // Prefer a cookie scoped to the console host when the value encodes one.
            if let host, pair.value.contains(host) {
                return pair.value
            }
            fallback = pair.value
        }
        return fallback
    }

    private static func looksLikeLoginPage(_ html: String) -> Bool {
        let lowered = html.lowercased()
        return lowered.contains("passport.alibabacloud.com") ||
            lowered.contains("signin.aliyun.com") ||
            lowered.contains("account.alibabacloud.com/login") ||
            lowered.contains("login.qwencloud.com") ||
            (lowered.contains("login") && lowered.contains("password") && lowered.contains("sign in"))
    }

    private static func fetchData(
        session: URLSession,
        request: URLRequest,
        cookieHeader: String,
        dashboardCookieHeader: String) async throws -> Data
    {
        let delegate = RedirectCookieDelegate(
            apiHost: request.url?.host ?? "",
            apiPath: request.url?.path ?? "",
            apiCookieHeader: cookieHeader,
            dashboardCookieHeader: dashboardCookieHeader)
        let (data, response) = try await session.data(for: request, delegate: delegate)

        if let http = response as? HTTPURLResponse {
            Self.log.info(
                "Qwen Cloud HTTP response",
                metadata: [
                    "status": "\(http.statusCode)",
                    "contentType": http.value(forHTTPHeaderField: "Content-Type") ?? "unknown",
                    "bodyBytes": "\(data.count)",
                ])
            switch http.statusCode {
            case 200:
                break
            case 401, 403:
                throw QwenCloudUsageError.invalidCredentials
            default:
                throw QwenCloudUsageError.apiError("HTTP \(http.statusCode)")
            }
        }

        return data
    }

    static func redirectedRequest(
        response: HTTPURLResponse,
        request: URLRequest,
        cookieHeader: String) -> URLRequest?
    {
        guard let url = request.url, let host = url.host else { return nil }
        guard response.statusCode >= 300, response.statusCode < 400 else { return nil }
        guard url.scheme?.lowercased() == "https" else { return nil }

        var mutable = request
        let originalHost = self.dashboardURL.host ?? "home.qwencloud.com"
        let isSameHost = host.lowercased() == originalHost.lowercased()
        if isSameHost {
            mutable.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        } else {
            mutable.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return mutable
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

    static func cookieNames(from header: String) -> [String] {
        CookieHeaderNormalizer.pairs(from: header)
            .map(\.name)
            .filter { !$0.isEmpty }
            .uniquedSorted()
    }

    static func cookieNamesDescription(_ names: [String]) -> String {
        names.isEmpty ? "none" : names.joined(separator: ",")
    }

    private final class RedirectCookieDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let apiHost: String
        private let apiPath: String
        private let apiCookieHeader: String
        private let dashboardCookieHeader: String

        init(
            apiHost: String,
            apiPath: String,
            apiCookieHeader: String,
            dashboardCookieHeader: String)
        {
            self.apiHost = apiHost
            self.apiPath = apiPath
            self.apiCookieHeader = apiCookieHeader
            self.dashboardCookieHeader = dashboardCookieHeader
        }

        func urlSession(
            _: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest) async -> URLRequest?
        {
            guard let originalRequest = task.originalRequest else { return request }
            let acceptHeader = originalRequest.value(forHTTPHeaderField: "Accept")
            let isDashboardNavigation = acceptHeader?.contains("text/html") == true
            let cookieHeader = isDashboardNavigation ? self.dashboardCookieHeader : self.apiCookieHeader
            guard let redirected = QwenCloudUsageFetcher.redirectedRequest(
                response: response,
                request: request,
                cookieHeader: cookieHeader)
            else {
                return request
            }
            // Keep cookies pinned to the original API endpoint even if the console
            // bounces through a same-host path (e.g. locale prefixes) before api.json.
            if let url = redirected.url,
               url.host?.lowercased() == self.apiHost.lowercased(),
               url.path == self.apiPath,
               !isDashboardNavigation
            {
                var pinned = redirected
                pinned.setValue(self.apiCookieHeader, forHTTPHeaderField: "Cookie")
                return pinned
            }
            return redirected
        }
    }
}

extension [String] {
    fileprivate func uniquedSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}
