import Foundation

/// Request/response handling for the Qwen Cloud personal ("solo") token plan.
///
/// This edition is served by a different console gateway than the team edition: the
/// action is a generic ASPN passthrough (`IntlBroadScopeAspnGateway`) that tunnels a
/// REST path in the `params` payload, and the useful data is nested four levels deep
/// under `data.DataV2.data.data`.
enum AlibabaTokenPlanPersonalAPI {
    enum Endpoint: String, CaseIterable {
        case usage
        case subscription
        case quotaConfig = "quota-config"

        var apiName: String {
            "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/\(self.rawValue)"
        }
    }

    static let product = "sfm_bailian"
    static let action = "IntlBroadScopeAspnGateway"

    static func requestURL(baseURLString: String, endpoint: Endpoint) -> URL? {
        guard var components = URLComponents(string: baseURLString) else { return nil }
        components.path = "/data/api.json"
        components.queryItems = [
            URLQueryItem(name: "product", value: Self.product),
            URLQueryItem(name: "action", value: Self.action),
            URLQueryItem(name: "api", value: endpoint.apiName),
        ]
        return components.url
    }

    static func requestBody(
        endpoint: Endpoint,
        region: AlibabaTokenPlanAPIRegion,
        secToken: String?) -> Data
    {
        let params: [String: Any] = [
            "Api": endpoint.apiName,
            "Data": [
                "cornerstoneParam": [
                    "domain": "home.qwencloud.com",
                    "consoleSite": "QWENCLOUD",
                    "console": "ONE_CONSOLE",
                    "xsp_lang": "en-US",
                    "protocol": "V2",
                    "productCode": "p_efm",
                ],
            ],
            "V": "1.0",
        ]
        guard let paramsData = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]),
              let paramsString = String(data: paramsData, encoding: .utf8)
        else {
            return Data()
        }

        var queryItems = [
            URLQueryItem(name: "product", value: Self.product),
            URLQueryItem(name: "action", value: Self.action),
        ]
        if let secToken, !secToken.isEmpty {
            queryItems.append(URLQueryItem(name: "sec_token", value: secToken))
        }
        queryItems.append(URLQueryItem(name: "region", value: region.currentRegionID))
        queryItems.append(URLQueryItem(name: "params", value: paramsString))
        return AlibabaTokenPlanUsageFetcher.formEncodedBody(queryItems)
    }

    /// Unwraps the `data.DataV2.data.data` envelope and surfaces gateway-level failures.
    ///
    /// Stale sessions come back as HTTP 200 with an error code in the body, so failures are
    /// classified through the same login/token detector the team edition uses — otherwise the
    /// descriptor never recognises them as credential failures and never re-imports cookies.
    static func unwrapPayload(from data: Data) throws -> [String: Any] {
        guard !data.isEmpty else {
            throw AlibabaTokenPlanUsageError.parseFailed("Empty response body")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            if AlibabaTokenPlanUsageFetcher.isLikelyLoginHTML(data) {
                throw AlibabaTokenPlanUsageError.loginRequired
            }
            throw AlibabaTokenPlanUsageError.parseFailed("Invalid JSON response")
        }
        // The root mirrors the HTTP status in `code` and carries no detail of its own, so only
        // consult it when there is no envelope left to descend into.
        guard let outer = root["data"] as? [String: Any] else {
            try Self.throwIfFailed(root, codeKeys: ["errorCode", "code"], messageKeys: ["errorMsg", "message"])
            throw Self.missingEnvelope("Missing data envelope", root: root)
        }
        try Self.throwIfFailed(outer, codeKeys: ["errorCode", "code"], messageKeys: ["errorMsg", "message"])
        guard let dataV2 = outer["DataV2"] as? [String: Any],
              let inner = dataV2["data"] as? [String: Any]
        else {
            throw Self.missingEnvelope("Missing DataV2 payload", root: root)
        }
        try Self.throwIfFailed(inner, codeKeys: ["code", "errorCode"], messageKeys: ["msg", "message"])
        guard let payload = inner["data"] as? [String: Any] else {
            throw Self.missingEnvelope("Missing payload body", root: root)
        }
        return payload
    }

    /// An envelope can go missing simply because the gateway replaced it with a login/auth error
    /// that carries no `success` flag. Sweep the whole body before giving up, so those still
    /// classify as credential failures and trigger a cookie re-import instead of a parse error.
    private static func missingEnvelope(_ reason: String, root: [String: Any]) -> AlibabaTokenPlanUsageError {
        let codes = ["errorCode", "code", "errorMsg", "msg", "message", "ret"].compactMap { key in
            AlibabaTokenPlanUsageFetcher.findFirstString(forKeys: [key], in: root)
        }
        if AlibabaTokenPlanUsageFetcher.isLoginOrTokenError(code: codes.joined(separator: " "), message: nil) {
            return .loginRequired
        }
        return .parseFailed(reason)
    }

    private static func throwIfFailed(
        _ dictionary: [String: Any],
        codeKeys: [String],
        messageKeys: [String]) throws
    {
        let successKeys = ["success", "successResponse"]
        let failed = successKeys.contains { key in
            dictionary[key].map { AlibabaTokenPlanUsageFetcher.parseBool($0) == false } ?? false
        }
        guard failed else { return }
        let code = codeKeys.lazy.compactMap { AlibabaTokenPlanUsageFetcher.parseString(dictionary[$0]) }.first
        let message = messageKeys.lazy.compactMap { AlibabaTokenPlanUsageFetcher.parseString(dictionary[$0]) }.first
        if AlibabaTokenPlanUsageFetcher.isLoginOrTokenError(code: code, message: message) {
            throw AlibabaTokenPlanUsageError.loginRequired
        }
        throw AlibabaTokenPlanUsageError.apiError(message ?? code ?? "Unknown gateway error")
    }

    struct UsagePayload: Sendable, Equatable {
        let fiveHourPercent: Double
        let fiveHourResetsAt: Date?
        let weeklyPercent: Double
        let weeklyResetsAt: Date?
    }

    /// Percentages arrive as fractions of 1.0 (0.0105 == 1.05% consumed).
    static func parseUsage(from data: Data) throws -> UsagePayload {
        let payload = try self.unwrapPayload(from: data)
        guard let fiveHour = self.double(payload["per5HourPercentage"]),
              let weekly = self.double(payload["per1WeekPercentage"])
        else {
            throw AlibabaTokenPlanUsageError.parseFailed(
                "Missing usage percentages (keys: \(payload.keys.sorted().joined(separator: ",")))")
        }
        return UsagePayload(
            fiveHourPercent: fiveHour * 100,
            fiveHourResetsAt: self.date(payload["per5HourResetTime"]),
            weeklyPercent: weekly * 100,
            weeklyResetsAt: self.date(payload["per1WeekResetTime"]))
    }

    struct SubscriptionPayload: Sendable, Equatable {
        let specCode: String?
        let status: String?
    }

    static func parseSubscription(from data: Data) throws -> SubscriptionPayload {
        let payload = try self.unwrapPayload(from: data)
        return SubscriptionPayload(
            specCode: payload["specCode"] as? String,
            status: payload["status"] as? String)
    }

    /// Maps tier name (`lite`, `standard`, `pro`) to that tier's credit ceilings. Keys are
    /// lowercased so lookups by `specCode` are case-insensitive.
    static func parseQuotaConfig(from data: Data) throws -> [String: (fiveHour: Double, weekly: Double)] {
        let payload = try self.unwrapPayload(from: data)
        var result: [String: (fiveHour: Double, weekly: Double)] = [:]
        for (tier, value) in payload {
            guard let entry = value as? [String: Any],
                  let fiveHour = self.double(entry["five_hour"]),
                  let weekly = self.double(entry["weekly"])
            else { continue }
            result[tier.lowercased()] = (fiveHour: fiveHour, weekly: weekly)
        }
        guard !result.isEmpty else {
            throw AlibabaTokenPlanUsageError.parseFailed(
                "No tier ceilings in quota-config (keys: \(payload.keys.sorted().joined(separator: ",")))")
        }
        return result
    }

    static func tier(
        for specCode: String?,
        in config: [String: (fiveHour: Double, weekly: Double)]?) -> (fiveHour: Double, weekly: Double)?
    {
        guard let specCode, let config else { return nil }
        return config[specCode.lowercased()]
    }

    private static let tierDisplayNames = ["lite": "Lite", "standard": "Standard", "pro": "Pro"]

    static func planName(specCode: String?, status: String? = nil) -> String {
        var name = "Token Plan"
        if let specCode, !specCode.isEmpty {
            name += " \(self.tierDisplayNames[specCode.lowercased()] ?? specCode)"
        }
        // Surface a lapsed subscription; windows keep reporting after a plan stops being VALID.
        if let status, !status.isEmpty, status.uppercased() != "VALID" {
            name += " (\(status.uppercased()))"
        }
        return name
    }

    private static func double(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
    }

    /// Timestamps are epoch milliseconds.
    private static func date(_ raw: Any?) -> Date? {
        guard let millis = self.double(raw), millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
