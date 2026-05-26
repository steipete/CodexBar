import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AlibabaTokenPlanUsageError: LocalizedError, Sendable, Equatable {
    case loginRequired
    case invalidCredentials
    case apiError(String)
    case networkError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .loginRequired:
            "Alibaba Token Plan login required."
        case .invalidCredentials:
            "Alibaba Token Plan credentials are invalid."
        case let .apiError(message):
            "Alibaba Token Plan API error: \(message)"
        case let .networkError(message):
            "Alibaba Token Plan network error: \(message)"
        case let .parseFailed(message):
            "Could not parse Alibaba Token Plan usage: \(message)"
        }
    }
}

public struct AlibabaTokenPlanUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger("alibaba-token-plan")
    private static let gatewayBaseURLString = "https://bailian.console.aliyun.com"
    private static let dashboardOriginURLString = "https://bailian.console.aliyun.com"
    private static let currentRegionID = "cn-beijing"
    private static let bssServiceCode = "BssOpenAPI-V3"
    private static let subscriptionSummaryAction = "GetSubscriptionSummary"
    private static let tokenPlanProductCode = "sfm_tokenplanteams_dp_cn"
    private static let browserLikeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let safariLikeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15"

    public static var dashboardURL: URL {
        URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan")!
    }

    public static func fetchUsage(
        cookieHeader: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> AlibabaTokenPlanUsageSnapshot
    {
        guard let headers = AlibabaTokenPlanCookieHeaders(singleHeader: cookieHeader) else {
            throw AlibabaTokenPlanSettingsError.invalidCookie
        }
        return try await self.fetchUsage(
            apiCookieHeader: headers.apiCookieHeader,
            dashboardCookieHeader: headers.dashboardCookieHeader,
            environment: environment,
            now: now)
    }

    static func fetchUsage(
        apiCookieHeader: String,
        dashboardCookieHeader: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        session overrideSession: URLSession? = nil) async throws -> AlibabaTokenPlanUsageSnapshot
    {
        guard let normalizedAPIHeader = CookieHeaderNormalizer.normalize(apiCookieHeader),
              let normalizedDashboardHeader = CookieHeaderNormalizer.normalize(dashboardCookieHeader)
        else {
            throw AlibabaTokenPlanSettingsError.invalidCookie
        }

        let url = self.resolveQuotaURL(environment: environment)
        let apiRedirectDiagnostics = RedirectDiagnostics(cookieHeader: normalizedAPIHeader)
        let dashboardRedirectDiagnostics: RedirectDiagnostics?
        let apiSession: URLSession
        let dashboardSession: URLSession
        if let overrideSession {
            apiSession = overrideSession
            dashboardSession = overrideSession
            dashboardRedirectDiagnostics = nil
        } else {
            let dashboardDiagnostics = RedirectDiagnostics(cookieHeader: normalizedDashboardHeader)
            apiSession = URLSession(
                configuration: .default,
                delegate: apiRedirectDiagnostics,
                delegateQueue: nil)
            dashboardSession = URLSession(
                configuration: .default,
                delegate: dashboardDiagnostics,
                delegateQueue: nil)
            dashboardRedirectDiagnostics = dashboardDiagnostics
        }
        defer {
            if overrideSession == nil {
                apiSession.invalidateAndCancel()
                dashboardSession.invalidateAndCancel()
            }
        }
        let secToken = await self.resolveSECToken(
            dashboardCookieHeader: normalizedDashboardHeader,
            apiCookieHeader: normalizedAPIHeader,
            environment: environment,
            session: dashboardSession)
        Self.log.info(
            "Fetching Alibaba Token Plan usage",
            metadata: [
                "apiHost": url.host ?? "unknown",
                "apiCookieNames": self.cookieNamesDescription(from: normalizedAPIHeader),
                "dashboardCookieNames": self.cookieNamesDescription(from: normalizedDashboardHeader),
                "hasCSRF": self.hasCSRF(in: normalizedAPIHeader) ? "1" : "0",
                "secTokenSource": secToken == nil ? "missing" : "resolved",
            ])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = self.subscriptionSummaryRequestBody(secToken: secToken)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(normalizedAPIHeader, forHTTPHeaderField: "Cookie")
        if let csrf = self.extractCookieValue(name: "login_aliyunid_csrf", from: normalizedAPIHeader) ??
            self.extractCookieValue(name: "csrf", from: normalizedAPIHeader)
        {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(Self.browserLikeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.dashboardOriginURLString, forHTTPHeaderField: "Origin")
        request.setValue(Self.dashboardURL.absoluteString, forHTTPHeaderField: "Referer")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await apiSession.data(for: request)
        } catch {
            Self.log.error(
                "Alibaba Token Plan request failed",
                metadata: [
                    "apiHost": url.host ?? "unknown",
                    "error": error.localizedDescription,
                ])
            throw AlibabaTokenPlanUsageError.networkError(error.localizedDescription)
        }
        if let dashboardRedirectDiagnostics, !dashboardRedirectDiagnostics.redirects.isEmpty {
            Self.log.info(
                "Alibaba Token Plan dashboard redirects",
                metadata: [
                    "count": "\(dashboardRedirectDiagnostics.redirects.count)",
                    "items": dashboardRedirectDiagnostics.redirects.joined(separator: " | "),
                ])
        }
        if !apiRedirectDiagnostics.redirects.isEmpty {
            Self.log.info(
                "Alibaba Token Plan redirects",
                metadata: [
                    "count": "\(apiRedirectDiagnostics.redirects.count)",
                    "items": apiRedirectDiagnostics.redirects.joined(separator: " | "),
                ])
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            Self.log.error("Alibaba Token Plan response was not HTTP")
            throw AlibabaTokenPlanUsageError.networkError("Invalid response")
        }
        Self.log.info(
            "Alibaba Token Plan HTTP response",
            metadata: [
                "status": "\(httpResponse.statusCode)",
                "bodyBytes": "\(data.count)",
                "contentType": httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "none",
            ])
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw AlibabaTokenPlanUsageError.loginRequired
            }
            Self.log.error("Alibaba Token Plan returned HTTP \(httpResponse.statusCode)")
            throw AlibabaTokenPlanUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        return try self.parseUsageSnapshot(from: data, now: now)
    }

    static func resolveQuotaURL(environment: [String: String]) -> URL {
        if let override = AlibabaTokenPlanSettingsReader.quotaURL(environment: environment) {
            return override
        }
        if let host = AlibabaTokenPlanSettingsReader.hostOverride(environment: environment),
           let hostURL = self.quotaURL(from: host)
        {
            return hostURL
        }
        return self.defaultQuotaURL
    }

    static var defaultQuotaURL: URL {
        var components = URLComponents(string: Self.gatewayBaseURLString)!
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "action", value: Self.subscriptionSummaryAction),
            URLQueryItem(name: "product", value: Self.bssServiceCode),
            URLQueryItem(name: "_tag", value: ""),
        ]
        return components.url!
    }

    static func parseUsageSnapshot(from data: Data, now: Date = Date()) throws -> AlibabaTokenPlanUsageSnapshot {
        guard !data.isEmpty else {
            throw AlibabaTokenPlanUsageError.parseFailed("Empty response body")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            if self.isLikelyLoginHTML(data) {
                throw AlibabaTokenPlanUsageError.loginRequired
            }
            throw AlibabaTokenPlanUsageError.parseFailed("Invalid JSON response")
        }
        let expanded = self.expandedJSON(object)
        guard let dictionary = expanded as? [String: Any] else {
            throw AlibabaTokenPlanUsageError.parseFailed("Unexpected payload")
        }

        try self.throwIfErrorPayload(dictionary)

        let summary = self.findSubscriptionSummary(in: dictionary) ?? dictionary
        let total = self.anyDouble(for: Self.totalQuotaKeys, in: summary)
        let remaining = self.anyDouble(for: Self.remainingQuotaKeys, in: summary)
        let used = self.anyDouble(for: Self.usedQuotaKeys, in: summary) ??
            total.flatMap { total in remaining.map { max(0, total - $0) } }
        let resetsAt = self.findResetDate(in: summary) ?? self.findResetDate(in: dictionary)
        let totalCount = self.anyDouble(for: Self.subscriptionCountKeys, in: summary)
        let planName = self.findPlanName(in: summary) ?? ((totalCount ?? 0) > 0 || total != nil ? "TOKEN PLAN" : nil)

        if planName == nil, total == nil, used == nil, remaining == nil, totalCount == nil {
            let diagnostics = self.payloadDiagnostics(payload: dictionary)
            Self.log.error("Alibaba Token Plan payload missing expected fields: \(diagnostics)")
            throw AlibabaTokenPlanUsageError.parseFailed("Missing token plan data (\(diagnostics))")
        }

        return AlibabaTokenPlanUsageSnapshot(
            planName: planName,
            usedQuota: used,
            totalQuota: total,
            remainingQuota: remaining,
            resetsAt: resetsAt,
            updatedAt: now)
    }

    private static func subscriptionSummaryRequestBody(secToken: String?) -> Data {
        let paramsObject = ["ProductCode": Self.tokenPlanProductCode]
        guard let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject, options: []),
              let paramsString = String(data: paramsData, encoding: .utf8)
        else {
            return Data()
        }

        var components = URLComponents()
        var queryItems = [
            URLQueryItem(name: "product", value: Self.bssServiceCode),
            URLQueryItem(name: "action", value: Self.subscriptionSummaryAction),
            URLQueryItem(name: "params", value: paramsString),
            URLQueryItem(name: "region", value: Self.currentRegionID),
        ]
        if let secToken, !secToken.isEmpty {
            queryItems.append(URLQueryItem(name: "sec_token", value: secToken))
        }
        components.queryItems = queryItems
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func resolveSECToken(
        dashboardCookieHeader: String,
        apiCookieHeader: String,
        environment: [String: String],
        session: URLSession) async -> String?
    {
        let cookieSECToken = self.extractCookieValue(name: "sec_token", from: dashboardCookieHeader) ??
            self.extractCookieValue(name: "sec_token", from: apiCookieHeader)
        var request = URLRequest(url: self.dashboardURL(environment: environment))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(dashboardCookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.safariLikeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")

        if let (data, response) = try? await session.data(for: request),
           let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 200,
           let html = String(data: data, encoding: .utf8),
           let token = self.extractSECToken(from: html)
        {
            Self.log.info(
                "Resolved Alibaba Token Plan sec_token from dashboard HTML",
                metadata: [
                    "dashboardHost": request.url?.host ?? "unknown",
                    "htmlBytes": "\(data.count)",
                ])
            return token
        }

        if let cookieSECToken, !cookieSECToken.isEmpty {
            Self.log.info("Resolved Alibaba Token Plan sec_token from cookies")
            return cookieSECToken
        }

        Self.log.info(
            "Alibaba Token Plan sec_token missing; continuing with cookie-only request",
            metadata: [
                "dashboardCookieNames": self.cookieNamesDescription(from: dashboardCookieHeader),
                "apiCookieNames": self.cookieNamesDescription(from: apiCookieHeader),
            ])
        return nil
    }

    private static func quotaURL(from rawHost: String) -> URL? {
        let cleaned = AlibabaTokenPlanSettingsReader.cleaned(rawHost)
        guard let cleaned else { return nil }
        let base = URL(string: cleaned)?.scheme == nil ? URL(string: "https://\(cleaned)") : URL(string: cleaned)
        guard let base else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let defaultComponents = URLComponents(url: Self.defaultQuotaURL, resolvingAgainstBaseURL: false)
        components?.path = "/data/api.json"
        components?.queryItems = defaultComponents?.queryItems
        return components?.url
    }

    static func dashboardURL(environment: [String: String]) -> URL {
        if let host = AlibabaTokenPlanSettingsReader.hostOverride(environment: environment),
           let base = URL(string: host)?.scheme == nil ? URL(string: "https://\(host)") : URL(string: host),
           var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
           let dashboardComponents = URLComponents(url: dashboardURL, resolvingAgainstBaseURL: false)
        {
            components.path = dashboardComponents.path
            components.percentEncodedQuery = dashboardComponents.percentEncodedQuery
            components.fragment = dashboardComponents.fragment
            return components.url ?? self.dashboardURL
        }
        return Self.dashboardURL
    }

    private final class RedirectDiagnostics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let cookieHeader: String
        var redirects: [String] = []

        init(cookieHeader: String) {
            self.cookieHeader = cookieHeader
        }

        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void)
        {
            let from = AlibabaTokenPlanUsageFetcher.redactedURLDescription(response.url)
            let to = AlibabaTokenPlanUsageFetcher.redactedURLDescription(request.url)
            self.redirects.append("\(response.statusCode) \(from) -> \(to)")

            completionHandler(AlibabaTokenPlanUsageFetcher.redirectedRequest(
                response: response,
                request: request,
                cookieHeader: self.cookieHeader))
        }
    }

    private static func redactedURLDescription(_ url: URL?) -> String {
        guard let url else { return "unknown" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "unknown")"
    }

    static func redirectedRequest(
        response: HTTPURLResponse,
        request: URLRequest,
        cookieHeader: String) -> URLRequest?
    {
        guard request.url?.scheme?.lowercased() == "https" else {
            return nil
        }

        var updated = request
        if self.shouldForwardRedirectCookies(from: response.url, to: request.url) {
            updated.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        } else {
            updated.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return updated
    }

    private static func shouldForwardRedirectCookies(from sourceURL: URL?, to targetURL: URL?) -> Bool {
        guard let sourceHost = sourceURL?.host?.lowercased(),
              let targetHost = targetURL?.host?.lowercased()
        else {
            return false
        }
        return sourceHost == targetHost
    }

    private static func throwIfErrorPayload(_ dictionary: [String: Any]) throws {
        if self.findBoolValues(forKeys: ["Success", "success"], in: dictionary).contains(false) {
            let message = self.findFirstString(forKeys: ["Message", "message", "msg", "Code", "code"], in: dictionary)
                ?? "request was not successful"
            let lowered = message.lowercased()
            if lowered.contains("needlogin") || lowered.contains("login") {
                throw AlibabaTokenPlanUsageError.loginRequired
            }
            throw AlibabaTokenPlanUsageError.apiError(message)
        }

        if let statusCode = self.findFirstInt(forKeys: ["statusCode", "status_code", "code"], in: dictionary),
           statusCode != 0,
           statusCode != 200
        {
            let message = self.findFirstString(
                forKeys: ["statusMessage", "status_msg", "message", "msg"],
                in: dictionary)
                ?? "status code \(statusCode)"
            if statusCode == 401 || statusCode == 403 {
                throw AlibabaTokenPlanUsageError.invalidCredentials
            }
            throw AlibabaTokenPlanUsageError.apiError(message)
        }

        let codeText = self.findFirstString(forKeys: ["code", "status", "statusCode"], in: dictionary)?.lowercased()
        let messageText = self.findFirstString(forKeys: ["message", "msg", "statusMessage"], in: dictionary)?
            .lowercased()
        if codeText?.contains("needlogin") == true ||
            codeText?.contains("login") == true ||
            messageText?.contains("log in") == true ||
            messageText?.contains("login") == true
        {
            throw AlibabaTokenPlanUsageError.loginRequired
        }
    }

    private static let planNameKeys = [
        "planName",
        "plan_name",
        "packageName",
        "package_name",
        "commodityName",
        "commodity_name",
        "instanceName",
        "instance_name",
        "displayName",
        "display_name",
        "ProductName",
        "productName",
        "name",
        "title",
        "planType",
        "plan_type",
    ]
    private static let usedQuotaKeys = [
        "usedQuota",
        "used_quota",
        "usedCredits",
        "usedCredit",
        "consumedCredits",
        "usage",
        "used",
        "usedAmount",
        "consumeAmount",
        "usedValue",
        "UsedValue",
        "consumedValue",
        "ConsumedValue",
    ]
    private static let totalQuotaKeys = [
        "totalQuota",
        "total_quota",
        "totalCredits",
        "totalCredit",
        "quota",
        "creditLimit",
        "creditsTotal",
        "monthlyTotalQuota",
        "amount",
        "totalValue",
        "TotalValue",
    ]
    private static let remainingQuotaKeys = [
        "remainingQuota",
        "remainQuota",
        "remainingCredits",
        "remainingCredit",
        "availableCredits",
        "balance",
        "remaining",
        "availableAmount",
        "remainAmount",
        "totalSurplusValue",
        "TotalSurplusValue",
        "surplusValue",
        "SurplusValue",
    ]
    private static let subscriptionCountKeys = [
        "totalCount",
        "TotalCount",
        "subscriptionTotalNumber",
        "SubscriptionTotalNumber",
    ]
    private static let resetDateKeys = [
        "nextRefreshTime",
        "resetTime",
        "periodEndTime",
        "billingCycleEnd",
        "billCycleEndTime",
        "expireTime",
        "expirationTime",
        "endTime",
        "validEndTime",
        "instanceEndTime",
        "nearestExpireDate",
        "NearestExpireDate",
    ]

    private static func findSubscriptionSummary(in payload: [String: Any]) -> [String: Any]? {
        if let data = self.findFirstDictionary(
            forKeys: ["Data", "data", "successResponse", "success_response"],
            in: payload),
            self.containsSubscriptionSummaryFields(data)
        {
            return data
        }
        return self.findFirstDictionary(
            matchingAnyKey: Self.usedQuotaKeys + Self.totalQuotaKeys + Self.remainingQuotaKeys +
                Self.subscriptionCountKeys,
            in: payload)
    }

    private static func containsSubscriptionSummaryFields(_ payload: [String: Any]) -> Bool {
        let keys = self.usedQuotaKeys + self.totalQuotaKeys + self.remainingQuotaKeys + self.subscriptionCountKeys
        return keys.contains { payload[$0] != nil }
    }

    private static func findPlanName(in payload: [String: Any]) -> String? {
        self.anyString(for: self.planNameKeys, in: payload) ??
            self.findFirstString(forKeys: self.planNameKeys, in: payload)
    }

    private static func findResetDate(in payload: [String: Any]) -> Date? {
        self.anyDate(for: self.resetDateKeys, in: payload) ??
            self.findFirstDate(forKeys: self.resetDateKeys, in: payload)
    }

    private static func payloadDiagnostics(payload: [String: Any]) -> String {
        let topKeys = payload.keys.sorted()
        let dataDict = self.findFirstDictionary(
            forKeys: ["Data", "data", "successResponse", "success_response"],
            in: payload)
        let dataKeys = dataDict?.keys.sorted() ?? []
        return "topKeys=\(topKeys.joined(separator: ",")) dataKeys=\(dataKeys.joined(separator: ","))"
    }

    private static func isLikelyLoginHTML(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("<html") &&
            (text.contains("login") || text.contains("sign in") || text.contains("signin"))
    }

    private static func findFirstDictionary(forKeys keys: [String], in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let nested = dict[key] as? [String: Any] {
                    return nested
                }
            }
            for nestedValue in dict.values {
                if let nested = self.findFirstDictionary(forKeys: keys, in: nestedValue) {
                    return nested
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for item in array {
                if let nested = self.findFirstDictionary(forKeys: keys, in: item) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func findFirstDictionary(matchingAnyKey keys: [String], in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if keys.contains(where: { dict[$0] != nil }) {
                return dict
            }
            for nestedValue in dict.values {
                if let nested = self.findFirstDictionary(matchingAnyKey: keys, in: nestedValue) {
                    return nested
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for item in array {
                if let nested = self.findFirstDictionary(matchingAnyKey: keys, in: item) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func findFirstString(forKeys keys: [String], in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let parsed = self.parseString(dict[key]) {
                    return parsed
                }
            }
            for nestedValue in dict.values {
                if let parsed = self.findFirstString(forKeys: keys, in: nestedValue) {
                    return parsed
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for item in array {
                if let parsed = self.findFirstString(forKeys: keys, in: item) {
                    return parsed
                }
            }
        }
        return nil
    }

    private static func findBoolValues(forKeys keys: [String], in value: Any) -> [Bool] {
        if let dict = value as? [String: Any] {
            let directValues = keys.compactMap { self.parseBool(dict[$0]) }
            let nestedValues = dict.values.flatMap { self.findBoolValues(forKeys: keys, in: $0) }
            return directValues + nestedValues
        }
        if let array = value as? [Any] {
            return array.flatMap { self.findBoolValues(forKeys: keys, in: $0) }
        }
        return []
    }

    private static func findFirstInt(forKeys keys: [String], in value: Any) -> Int? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let parsed = self.parseInt(dict[key]) {
                    return parsed
                }
            }
            for nestedValue in dict.values {
                if let parsed = self.findFirstInt(forKeys: keys, in: nestedValue) {
                    return parsed
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for item in array {
                if let parsed = self.findFirstInt(forKeys: keys, in: item) {
                    return parsed
                }
            }
        }
        return nil
    }

    private static func findFirstDate(forKeys keys: [String], in value: Any) -> Date? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let parsed = self.parseDate(dict[key]) {
                    return parsed
                }
            }
            for nestedValue in dict.values {
                if let parsed = self.findFirstDate(forKeys: keys, in: nestedValue) {
                    return parsed
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for item in array {
                if let parsed = self.findFirstDate(forKeys: keys, in: item) {
                    return parsed
                }
            }
        }
        return nil
    }

    private static func expandedJSON(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var expanded: [String: Any] = [:]
            expanded.reserveCapacity(dict.count)
            for (key, nested) in dict {
                expanded[key] = self.expandedJSON(nested)
            }
            return expanded
        }
        if let array = value as? [Any] {
            return array.map { self.expandedJSON($0) }
        }
        if let string = value as? String,
           let data = string.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: data, options: []),
           nested is [String: Any] || nested is [Any]
        {
            return self.expandedJSON(nested)
        }
        return value
    }

    private static func anyString(for keys: [String], in dict: [String: Any]) -> String? {
        for key in keys {
            if let value = self.parseString(dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func anyDouble(for keys: [String], in dict: [String: Any]) -> Double? {
        for key in keys {
            if let value = self.parseDouble(dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func anyDate(for keys: [String], in dict: [String: Any]) -> Date? {
        for key in keys {
            if let value = self.parseDate(dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func anyBool(for keys: [String], in dict: [String: Any]) -> Bool? {
        for key in keys {
            if let value = self.parseBool(dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func parseInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Int64 { return Int(value) }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = self.parseString(raw) { return Int(value) }
        return nil
    }

    private static func parseDouble(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? Int64 { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = self.parseString(raw) {
            let cleaned = value.replacingOccurrences(of: ",", with: "")
            return Double(cleaned)
        }
        return nil
    }

    private static func parseString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        if let intValue = self.parseInt(raw) {
            if intValue > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: TimeInterval(intValue) / 1000)
            }
            if intValue > 1_000_000_000 {
                return Date(timeIntervalSince1970: TimeInterval(intValue))
            }
        }
        if let string = self.parseString(raw) {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) {
                return date
            }
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            for format in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
                dateFormatter.dateFormat = format
                if let date = dateFormatter.date(from: string) {
                    return date
                }
            }
        }
        return nil
    }

    private static func parseBool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        guard let string = self.parseString(raw)?.lowercased() else { return nil }
        switch string {
        case "true", "1", "yes", "active", "valid", "normal":
            return true
        case "false", "0", "no", "inactive", "invalid", "expired":
            return false
        default:
            return nil
        }
    }

    private static func extractCookieValue(name: String, from cookieHeader: String) -> String? {
        cookieHeader
            .split(separator: ";")
            .compactMap { part -> (String, String)? in
                let pieces = part.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard pieces.count == 2 else { return nil }
                return (pieces[0], pieces[1])
            }
            .first { $0.0 == name }?
            .1
    }

    private static func hasCSRF(in cookieHeader: String) -> Bool {
        self.extractCookieValue(name: "login_aliyunid_csrf", from: cookieHeader) != nil ||
            self.extractCookieValue(name: "csrf", from: cookieHeader) != nil
    }

    static func cookieNames(from cookieHeader: String) -> [String] {
        CookieHeaderNormalizer.pairs(from: cookieHeader)
            .map(\.name)
            .filter { !$0.isEmpty }
            .uniquedSorted()
    }

    static func cookieNamesDescription(from cookieHeader: String) -> String {
        let names = self.cookieNames(from: cookieHeader)
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    private static func extractSECToken(from html: String) -> String? {
        let patterns = [
            #""secToken"\s*:\s*"([^"]+)""#,
            #""sec_token"\s*:\s*"([^"]+)""#,
            #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
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
}

extension [String] {
    fileprivate func uniquedSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}
