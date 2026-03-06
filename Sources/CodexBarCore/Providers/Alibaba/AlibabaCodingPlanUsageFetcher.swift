import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AlibabaCodingPlanUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger("alibaba-coding-plan")
    private static let browserLikeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let safariLikeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15"

    public static func fetchUsage(
        apiKey: String,
        region: AlibabaCodingPlanAPIRegion = .international,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> AlibabaCodingPlanUsageSnapshot
    {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw AlibabaCodingPlanUsageError.invalidCredentials
        }

        if region != .international {
            return try await self.fetchUsageOnce(
                apiKey: cleanedKey,
                region: region,
                environment: environment,
                now: now)
        }

        do {
            return try await self.fetchUsageOnce(
                apiKey: cleanedKey,
                region: .international,
                environment: environment,
                now: now)
        } catch let error as AlibabaCodingPlanUsageError {
            guard error.shouldRetryOnAlternateRegion else { throw error }
            Self.log.debug("Alibaba Coding Plan request failed on intl host; retrying cn host")
            return try await self.fetchUsageOnce(
                apiKey: cleanedKey,
                region: .chinaMainland,
                environment: environment,
                now: now)
        }
    }

    public static func fetchUsage(
        cookieHeader: String,
        region: AlibabaCodingPlanAPIRegion = .international,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> AlibabaCodingPlanUsageSnapshot
    {
        guard let normalizedCookie = CookieHeaderNormalizer.normalize(cookieHeader) else {
            throw AlibabaCodingPlanSettingsError.invalidCookie
        }

        if region != .international {
            return try await self.fetchUsageOnce(
                cookieHeader: normalizedCookie,
                region: region,
                environment: environment,
                now: now)
        }

        do {
            return try await self.fetchUsageOnce(
                cookieHeader: normalizedCookie,
                region: .international,
                environment: environment,
                now: now)
        } catch let error as AlibabaCodingPlanUsageError {
            guard error.shouldRetryOnAlternateRegion else { throw error }
            Self.log.debug("Alibaba Coding Plan cookie request failed on intl host; retrying cn host")
            return try await self.fetchUsageOnce(
                cookieHeader: normalizedCookie,
                region: .chinaMainland,
                environment: environment,
                now: now)
        }
    }

    private static func fetchUsageOnce(
        apiKey: String,
        region: AlibabaCodingPlanAPIRegion,
        environment: [String: String],
        now: Date) async throws -> AlibabaCodingPlanUsageSnapshot
    {
        let url = self.resolveQuotaURL(region: region, environment: environment)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = self.queryCodingPlanAPIRequestBody(region: region)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiKey, forHTTPHeaderField: "X-DashScope-API-Key")
        request.setValue(Self.browserLikeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(region.gatewayBaseURLString, forHTTPHeaderField: "Origin")
        request.setValue(region.dashboardURL.absoluteString, forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AlibabaCodingPlanUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw AlibabaCodingPlanUsageError.loginRequired
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("Alibaba Coding Plan returned \(httpResponse.statusCode): \(body)")
            throw AlibabaCodingPlanUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        return try self.parseUsageSnapshot(from: data, now: now)
    }

    private static func fetchUsageOnce(
        cookieHeader: String,
        region: AlibabaCodingPlanAPIRegion,
        environment: [String: String],
        now: Date) async throws -> AlibabaCodingPlanUsageSnapshot
    {
        let url = self.resolveConsoleQuotaURL(region: region, environment: environment)
        let secToken = try await self.resolveConsoleSECToken(
            cookieHeader: cookieHeader,
            region: region,
            environment: environment)
        let anonymousID = self.extractCookieValue(name: "cna", from: cookieHeader)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = self.queryCodingPlanConsoleRequestBody(
            region: region,
            secToken: secToken,
            anonymousID: anonymousID)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let csrf = self.extractCookieValue(name: "login_aliyunid_csrf", from: cookieHeader) ??
            self.extractCookieValue(name: "csrf", from: cookieHeader)
        {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(Self.browserLikeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(region.gatewayBaseURLString, forHTTPHeaderField: "Origin")
        request.setValue(region.consoleRefererURL.absoluteString, forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AlibabaCodingPlanUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw AlibabaCodingPlanUsageError.loginRequired
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("Alibaba Coding Plan returned \(httpResponse.statusCode): \(body)")
            throw AlibabaCodingPlanUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        return try self.parseUsageSnapshot(from: data, now: now)
    }

    private static func queryCodingPlanAPIRequestBody(region: AlibabaCodingPlanAPIRegion) -> Data {
        let payload: [String: Any] = [
            "queryCodingPlanInstanceInfoRequest": [
                "commodityCode": region.commodityCode,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
    }

    private static func queryCodingPlanConsoleRequestBody(
        region: AlibabaCodingPlanAPIRegion,
        secToken: String,
        anonymousID: String?) -> Data
    {
        let traceID = UUID().uuidString.lowercased()
        var cornerstoneParam: [String: Any] = [
            "feTraceId": traceID,
            "feURL": region.dashboardURL.absoluteString,
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "domain": "modelstudio.console.alibabacloud.com",
            "consoleSite": "MODELSTUDIO_ALBABACLOUD",
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": "en-US",
        ]
        if let anonymousID, !anonymousID.isEmpty {
            cornerstoneParam["X-Anonymous-Id"] = anonymousID
        }

        let paramsObject: [String: Any] = [
            "Api": region.consoleQuotaAPIName,
            "V": "1.0",
            "Data": [
                "queryCodingPlanInstanceInfoRequest": [
                    "commodityCode": region.commodityCode,
                    "onlyLatestOne": true,
                ],
                "cornerstoneParam": cornerstoneParam,
            ],
        ]

        guard let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject, options: []),
              let paramsString = String(data: paramsData, encoding: .utf8)
        else {
            return Data()
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "params", value: paramsString),
            URLQueryItem(name: "region", value: region.currentRegionID),
            URLQueryItem(name: "sec_token", value: secToken),
        ]
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    static func resolveConsoleQuotaURL(
        region: AlibabaCodingPlanAPIRegion,
        environment: [String: String]) -> URL
    {
        if let override = AlibabaCodingPlanSettingsReader.quotaURL(environment: environment) {
            return override
        }
        if let host = AlibabaCodingPlanSettingsReader.hostOverride(environment: environment),
           let hostURL = self.consoleURL(from: host, region: region)
        {
            return hostURL
        }
        return region.consoleRPCURL
    }

    static func resolveQuotaURL(
        region: AlibabaCodingPlanAPIRegion,
        environment: [String: String]) -> URL
    {
        if let override = AlibabaCodingPlanSettingsReader.quotaURL(environment: environment) {
            return override
        }
        if let host = AlibabaCodingPlanSettingsReader.hostOverride(environment: environment),
           let hostURL = self.url(from: host)
        {
            return hostURL
        }
        return region.quotaURL
    }

    static func url(from rawHost: String) -> URL? {
        let cleaned = AlibabaCodingPlanSettingsReader.cleaned(rawHost)
        guard let cleaned else { return nil }

        let base: URL?
        if let url = URL(string: cleaned), url.scheme != nil {
            base = url
        } else {
            base = URL(string: "https://\(cleaned)")
        }
        guard let base else { return nil }

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/data/api.json"
        components?.queryItems = [
            URLQueryItem(name: "action", value: "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "product", value: "broadscope-bailian"),
            URLQueryItem(name: "api", value: "queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "currentRegionId", value: AlibabaCodingPlanAPIRegion.international.currentRegionID),
        ]
        return components?.url
    }

    static func consoleURL(from rawHost: String, region: AlibabaCodingPlanAPIRegion) -> URL? {
        let cleaned = AlibabaCodingPlanSettingsReader.cleaned(rawHost)
        guard let cleaned else { return nil }

        let base: URL?
        if let url = URL(string: cleaned), url.scheme != nil {
            base = url
        } else {
            base = URL(string: "https://\(cleaned)")
        }
        guard let base else { return nil }

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/data/api.json"
        components?.queryItems = [
            URLQueryItem(name: "action", value: region.consoleRPCAction),
            URLQueryItem(name: "product", value: region.consoleRPCProduct),
            URLQueryItem(name: "api", value: region.consoleQuotaAPIName),
            URLQueryItem(name: "_v", value: "undefined"),
        ]
        return components?.url
    }

    private static func resolveConsoleSECToken(
        cookieHeader: String,
        region: AlibabaCodingPlanAPIRegion,
        environment: [String: String]) async throws -> String
    {
        if let sec = self.extractCookieValue(name: "sec_token", from: cookieHeader), !sec.isEmpty {
            return sec
        }

        let dashboardURL: URL
        if let override = AlibabaCodingPlanSettingsReader.hostOverride(environment: environment),
           let hostURL = URL(string: override),
           hostURL.scheme != nil
        {
            dashboardURL = hostURL
        } else {
            dashboardURL = region.dashboardURL
        }

        var request = URLRequest(url: dashboardURL)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.safariLikeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let html = String(data: data, encoding: .utf8)
        else {
            throw AlibabaCodingPlanUsageError.loginRequired
        }

        if let token = self.extractConsoleSECToken(from: html), !token.isEmpty {
            return token
        }

        if let token = try await self.fetchSECTokenFromUserInfo(cookieHeader: cookieHeader, region: region) {
            return token
        }

        throw AlibabaCodingPlanUsageError.loginRequired
    }

    private static func fetchSECTokenFromUserInfo(
        cookieHeader: String,
        region: AlibabaCodingPlanAPIRegion) async throws -> String?
    {
        let userInfoURL = URL(string: "\(region.gatewayBaseURLString)/tool/user/info.json")!
        var request = URLRequest(url: userInfoURL)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.safariLikeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(region.gatewayBaseURLString + "/", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let expanded = self.expandedJSON(object)
        return self.findFirstString(forKeys: ["secToken", "sec_token"], in: expanded)
    }

    static func parseUsageSnapshot(from data: Data, now: Date = Date()) throws -> AlibabaCodingPlanUsageSnapshot {
        guard !data.isEmpty else {
            throw AlibabaCodingPlanUsageError.parseFailed("Empty response body")
        }

        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let expanded = self.expandedJSON(object)
        guard let dictionary = expanded as? [String: Any] else {
            throw AlibabaCodingPlanUsageError.parseFailed("Unexpected payload")
        }

        if let statusCode = self.findFirstInt(forKeys: ["statusCode", "status_code", "code"], in: dictionary),
           statusCode != 0,
           statusCode != 200
        {
            let message = self.findFirstString(forKeys: ["statusMessage", "status_msg", "message", "msg"], in: dictionary)
                ?? "status code \(statusCode)"
            let lower = message.lowercased()
            if statusCode == 401 || statusCode == 403 || lower.contains("api key") || lower.contains("unauthorized") {
                throw AlibabaCodingPlanUsageError.invalidCredentials
            }
            throw AlibabaCodingPlanUsageError.apiError(message)
        }

        if let codeText = self.findFirstString(forKeys: ["code", "status", "statusCode"], in: dictionary) {
            let normalizedCode = codeText.lowercased()
            if normalizedCode.contains("needlogin") || normalizedCode.contains("login") {
                throw AlibabaCodingPlanUsageError.loginRequired
            }
        }
        if let messageText = self.findFirstString(forKeys: ["message", "msg", "statusMessage"], in: dictionary) {
            let normalizedMessage = messageText.lowercased()
            if normalizedMessage.contains("log in") || normalizedMessage.contains("login") {
                throw AlibabaCodingPlanUsageError.loginRequired
            }
        }

        let instanceInfo = self.findActiveInstanceInfo(in: dictionary)
        guard let quota = self.findQuotaInfo(in: dictionary) ?? self.findQuotaInfo(in: instanceInfo ?? [:]) else {
            if let fallback = self.parseWindowFromPlanUsage(payload: dictionary, instanceInfo: instanceInfo, now: now) {
                return fallback
            }
            if let fallback = self.parseActivePlanWithoutQuota(payload: dictionary, instanceInfo: instanceInfo, now: now) {
                return fallback
            }
            let diagnostics = self.payloadDiagnostics(payload: dictionary)
            Self.log.error("Alibaba coding plan quota payload missing expected fields: \(diagnostics)")
            throw AlibabaCodingPlanUsageError.parseFailed("Missing coding plan quota data (\(diagnostics))")
        }

        let planName = self.findPlanName(in: dictionary)

        let snapshot = AlibabaCodingPlanUsageSnapshot(
            planName: planName,
            fiveHourUsedQuota: self.anyInt(for: ["per5HourUsedQuota", "perFiveHourUsedQuota"], in: quota),
            fiveHourTotalQuota: self.anyInt(for: ["per5HourTotalQuota", "perFiveHourTotalQuota"], in: quota),
            fiveHourNextRefreshTime: self.anyDate(for: ["per5HourQuotaNextRefreshTime", "perFiveHourQuotaNextRefreshTime"], in: quota),
            weeklyUsedQuota: self.anyInt(for: ["perWeekUsedQuota"], in: quota),
            weeklyTotalQuota: self.anyInt(for: ["perWeekTotalQuota"], in: quota),
            weeklyNextRefreshTime: self.anyDate(for: ["perWeekQuotaNextRefreshTime"], in: quota),
            monthlyUsedQuota: self.anyInt(for: ["perBillMonthUsedQuota", "perMonthUsedQuota"], in: quota),
            monthlyTotalQuota: self.anyInt(for: ["perBillMonthTotalQuota", "perMonthTotalQuota"], in: quota),
            monthlyNextRefreshTime: self.anyDate(for: ["perBillMonthQuotaNextRefreshTime", "perMonthQuotaNextRefreshTime"], in: quota),
            updatedAt: now)

        if snapshot.fiveHourTotalQuota == nil,
           snapshot.weeklyTotalQuota == nil,
           snapshot.monthlyTotalQuota == nil
        {
            if let fallback = self.parseWindowFromPlanUsage(payload: dictionary, instanceInfo: instanceInfo, now: now) {
                return fallback
            }
            if let fallback = self.parseActivePlanWithoutQuota(payload: dictionary, instanceInfo: instanceInfo, now: now) {
                return fallback
            }
            let diagnostics = self.payloadDiagnostics(payload: dictionary)
            Self.log.error("Alibaba coding plan payload had no usable windows: \(diagnostics)")
            throw AlibabaCodingPlanUsageError.parseFailed("No quota windows found in payload (\(diagnostics))")
        }

        return snapshot
    }

    private static func findPlanName(in payload: [String: Any]) -> String? {
        if let infos = self.findFirstArray(forKeys: ["codingPlanInstanceInfos", "coding_plan_instance_infos"], in: payload) {
            for item in infos {
                guard let info = item as? [String: Any] else { continue }
                let candidates = [
                    self.anyString(for: ["planName", "plan_name"], in: info),
                    self.anyString(for: ["instanceName", "instance_name"], in: info),
                    self.anyString(for: ["packageName", "package_name"], in: info),
                ]
                for candidate in candidates {
                    if let candidate, !candidate.isEmpty {
                        return candidate
                    }
                }
            }
        }
        return self.findFirstString(forKeys: ["planName", "plan_name", "packageName", "package_name"], in: payload)
    }

    private static func findActiveInstanceInfo(in payload: [String: Any]) -> [String: Any]? {
        guard let infos = self.findFirstArray(forKeys: ["codingPlanInstanceInfos", "coding_plan_instance_infos"], in: payload)
        else {
            return nil
        }

        var first: [String: Any]?
        for item in infos {
            guard let info = item as? [String: Any] else { continue }
            first = first ?? info
            let status = self.anyString(for: ["status", "instanceStatus"], in: info)?.uppercased()
            if status == "VALID" || status == "ACTIVE" {
                return info
            }
        }
        return first
    }

    private static func parseWindowFromPlanUsage(
        payload: [String: Any],
        instanceInfo: [String: Any]?,
        now: Date) -> AlibabaCodingPlanUsageSnapshot?
    {
        let source = instanceInfo ?? payload
        let usagePercent =
            self.anyPercent(for: ["planUsage", "usageRate", "usage", "usageValue"], in: source) ??
            self.findFirstPercent(forKeys: ["planUsage", "usageRate", "usage", "usageValue"], in: payload)
        guard let usagePercent else { return nil }

        let roundedPercent = max(0, min(Int(usagePercent.rounded()), 100))
        let reset =
            self.anyDate(for: ["per5HourQuotaNextRefreshTime", "nextRefreshTime", "endTime", "periodEndTime"], in: source) ??
            self.findFirstDate(forKeys: ["per5HourQuotaNextRefreshTime", "nextRefreshTime", "endTime", "periodEndTime"], in: payload)

        return AlibabaCodingPlanUsageSnapshot(
            planName: self.findPlanName(in: payload),
            fiveHourUsedQuota: roundedPercent,
            fiveHourTotalQuota: 100,
            fiveHourNextRefreshTime: reset,
            weeklyUsedQuota: nil,
            weeklyTotalQuota: nil,
            weeklyNextRefreshTime: nil,
            monthlyUsedQuota: nil,
            monthlyTotalQuota: nil,
            monthlyNextRefreshTime: nil,
            updatedAt: now)
    }

    private static func parseActivePlanWithoutQuota(
        payload: [String: Any],
        instanceInfo: [String: Any]?,
        now: Date) -> AlibabaCodingPlanUsageSnapshot?
    {
        let source = instanceInfo ?? payload
        let status = self.anyString(for: ["status", "instanceStatus"], in: source)?.uppercased()
        if let status, status != "VALID", status != "ACTIVE" {
            return nil
        }

        let reset =
            self.anyDate(for: ["per5HourQuotaNextRefreshTime", "nextRefreshTime", "endTime", "periodEndTime"], in: source) ??
            self.findFirstDate(forKeys: ["per5HourQuotaNextRefreshTime", "nextRefreshTime", "endTime", "periodEndTime"], in: payload)

        return AlibabaCodingPlanUsageSnapshot(
            planName: self.findPlanName(in: payload),
            fiveHourUsedQuota: 0,
            fiveHourTotalQuota: 100,
            fiveHourNextRefreshTime: reset,
            weeklyUsedQuota: nil,
            weeklyTotalQuota: nil,
            weeklyNextRefreshTime: nil,
            monthlyUsedQuota: nil,
            monthlyTotalQuota: nil,
            monthlyNextRefreshTime: nil,
            updatedAt: now)
    }

    private static func payloadDiagnostics(payload: [String: Any]) -> String {
        let topKeys = payload.keys.sorted()
        let dataDict = self.findFirstDictionary(forKeys: ["data", "successResponse", "success_response"], in: payload)
        let dataKeys = dataDict?.keys.sorted() ?? []
        let instanceInfo = self.findActiveInstanceInfo(in: payload)
        let instanceKeys = instanceInfo?.keys.sorted() ?? []
        let hasQuota = self.findQuotaInfo(in: payload) != nil
        let planUsage =
            self.anyString(for: ["planUsage", "usageRate", "usage", "usageValue"], in: instanceInfo ?? [:]) ??
            self.findFirstString(forKeys: ["planUsage", "usageRate", "usage", "usageValue"], in: payload)
        let compactPlanUsage = planUsage?.replacingOccurrences(of: "\n", with: " ") ?? "none"
        let status = self.anyString(for: ["status", "instanceStatus"], in: instanceInfo ?? [:]) ?? "none"

        return "topKeys=\(topKeys.joined(separator: ",")) dataKeys=\(dataKeys.joined(separator: ",")) " +
            "instanceKeys=\(instanceKeys.joined(separator: ",")) hasQuota=\(hasQuota ? "1" : "0") " +
            "status=\(status) planUsage=\(compactPlanUsage)"
    }

    private static func findQuotaInfo(in payload: [String: Any]) -> [String: Any]? {
        if let direct = self.findFirstDictionary(forKeys: ["codingPlanQuotaInfo", "coding_plan_quota_info"], in: payload) {
            return direct
        }
        return self.findFirstDictionary(
            matchingAnyKey: [
                "per5HourUsedQuota",
                "per5HourTotalQuota",
                "perWeekUsedQuota",
                "perWeekTotalQuota",
                "perBillMonthUsedQuota",
                "perBillMonthTotalQuota",
            ],
            in: payload)
    }

    private static func findFirstDictionary(forKeys keys: [String], in value: Any) -> [String: Any]? {
        guard let dict = value as? [String: Any] else { return nil }
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

    private static func findFirstArray(forKeys keys: [String], in value: Any) -> [Any]? {
        guard let dict = value as? [String: Any] else {
            if let array = value as? [Any] {
                for item in array {
                    if let found = self.findFirstArray(forKeys: keys, in: item) {
                        return found
                    }
                }
            }
            return nil
        }
        for key in keys {
            if let array = dict[key] as? [Any] {
                return array
            }
        }
        for nested in dict.values {
            if let found = self.findFirstArray(forKeys: keys, in: nested) {
                return found
            }
        }
        return nil
    }

    private static func findFirstInt(forKeys keys: [String], in value: Any) -> Int? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let parsed = self.parseInt(dict[key]) {
                    return parsed
                }
            }
            for nested in dict.values {
                if let parsed = self.findFirstInt(forKeys: keys, in: nested) {
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

    private static func findFirstString(forKeys keys: [String], in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let parsed = self.parseString(dict[key]) {
                    return parsed
                }
            }
            for nested in dict.values {
                if let parsed = self.findFirstString(forKeys: keys, in: nested) {
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

    private static func findFirstDate(forKeys keys: [String], in value: Any) -> Date? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let parsed = self.parseDate(dict[key]) {
                    return parsed
                }
            }
            for nested in dict.values {
                if let parsed = self.findFirstDate(forKeys: keys, in: nested) {
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

    private static func anyInt(for keys: [String], in dict: [String: Any]) -> Int? {
        for key in keys {
            if let value = self.parseInt(dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func anyString(for keys: [String], in dict: [String: Any]) -> String? {
        for key in keys {
            if let value = self.parseString(dict[key]) {
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

    private static func anyPercent(for keys: [String], in dict: [String: Any]) -> Double? {
        for key in keys {
            if let value = self.parsePercent(dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func findFirstPercent(forKeys keys: [String], in value: Any) -> Double? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let parsed = self.parsePercent(dict[key]) {
                    return parsed
                }
            }
            for nested in dict.values {
                if let parsed = self.findFirstPercent(forKeys: keys, in: nested) {
                    return parsed
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for item in array {
                if let parsed = self.findFirstPercent(forKeys: keys, in: item) {
                    return parsed
                }
            }
        }
        return nil
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
            for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
                dateFormatter.dateFormat = format
                if let date = dateFormatter.date(from: string) {
                    return date
                }
            }
        }
        return nil
    }

    private static func parseInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Int64 { return Int(value) }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        }
        return nil
    }

    private static func parseString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parsePercent(_ raw: Any?) -> Double? {
        if let intValue = self.parseInt(raw) {
            return max(0, min(Double(intValue), 100))
        }
        guard let rawString = self.parseString(raw) else { return nil }
        let cleaned = rawString
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(cleaned) else { return nil }
        return max(0, min(parsed, 100))
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

    private static func extractConsoleSECToken(from html: String) -> String? {
        let patterns = [
            #"SEC_TOKEN\s*:\s*\"([^\"]+)\""#,
            #"SEC_TOKEN\s*:\s*'([^']+)'"#,
            #"secToken\s*:\s*\"([^\"]+)\""#,
            #"\"SEC_TOKEN\"\s*:\s*\"([^\"]+)\""#,
        ]

        for pattern in patterns {
            if let token = self.matchFirstGroup(pattern: pattern, in: html), !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private static func extractCookieValue(name: String, from cookieHeader: String) -> String? {
        let segments = cookieHeader.split(separator: ";")
        for segment in segments {
            let part = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = part.firstIndex(of: "=") else { continue }
            let key = String(part[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if key == name {
                let value = String(part[part.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

public enum AlibabaCodingPlanUsageError: LocalizedError, Sendable, Equatable {
    case loginRequired
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    var shouldRetryOnAlternateRegion: Bool {
        switch self {
        case .loginRequired:
            true
        case .invalidCredentials:
            true
        case let .apiError(message):
            message.contains("HTTP 404") || message.contains("HTTP 403")
        case let .parseFailed(message):
            message.contains("Missing coding plan quota data") || message.contains("No quota windows found")
        case .networkError:
            false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .loginRequired:
            "Alibaba Coding Plan console login is required. Sign in to Model Studio in a supported browser or paste a Cookie header."
        case .invalidCredentials:
            "Alibaba Coding Plan API credentials are invalid or expired."
        case let .networkError(message):
            "Alibaba Coding Plan network error: \(message)"
        case let .apiError(message):
            "Alibaba Coding Plan API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Alibaba Coding Plan response: \(message)"
        }
    }
}
