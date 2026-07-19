import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - API response types

/// A flexible number type that can decode from both JSON integers and floats.
/// The StepFun API returns `five_hour_usage_left_rate: 1` (int) or `0.99781543` (float).
public struct StepFunFlexibleNumber: Decodable, Sendable {
    public let value: Double

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self.value = Double(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self.value = doubleVal
        } else if let strVal = try? container.decode(String.self),
                  let parsed = Double(strVal)
        {
            // The API returns some numeric fields as JSON strings (e.g. "400000000").
            self.value = parsed
        } else {
            self.value = 0
        }
    }

    public init(_ value: Double) {
        self.value = value
    }
}

/// A flexible timestamp type that can decode from both JSON strings and integers.
/// The StepFun API returns timestamps as strings like `"1777528800"`.
public struct StepFunFlexibleTimestamp: Decodable, Sendable {
    public let value: Int64

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let strVal = try? container.decode(String.self), let parsed = Int64(strVal) {
            self.value = parsed
        } else if let intVal = try? container.decode(Int64.self) {
            self.value = intVal
        } else {
            self.value = 0
        }
    }

    public init(_ value: Int64) {
        self.value = value
    }
}

public struct StepFunRateLimitResponse: Decodable, Sendable {
    public let status: Int?
    public let code: Int?
    public let message: String?
    public let desc: String?
    public let fiveHourUsageLeftRate: StepFunFlexibleNumber?
    public let weeklyUsageLeftRate: StepFunFlexibleNumber?
    public let fiveHourUsageResetTime: StepFunFlexibleTimestamp?
    public let weeklyUsageResetTime: StepFunFlexibleTimestamp?
    public let planFamily: StepFunFlexibleNumber?
    public let planCreditRateLimit: StepFunPlanCreditRateLimit?

    enum CodingKeys: String, CodingKey {
        case status
        case code
        case message
        case desc
        case fiveHourUsageLeftRate = "five_hour_usage_left_rate"
        case weeklyUsageLeftRate = "weekly_usage_left_rate"
        case fiveHourUsageResetTime = "five_hour_usage_reset_time"
        case weeklyUsageResetTime = "weekly_usage_reset_time"
        case planFamily = "plan_family"
        case planCreditRateLimit = "plan_credit_rate_limit"
    }

    public var isSuccess: Bool {
        self.status == 1
    }

    /// Credit-based plans (plan_family=2) report usage via `plan_credit_rate_limit`
    /// instead of the five-hour / weekly rate windows. Those rate fields are 0 with
    /// reset_time "0" — meaning "no window configured", NOT "fully consumed".
    var isCreditPlan: Bool {
        // plan_family 2 = credit-based subscription plans (e.g. Mini, Pro).
        if let family = self.planFamily?.value, family > 0 {
            return family == 2
        }
        // Fallback heuristic: if both rate windows are 0 with no reset time, but
        // credit data is present, treat as a credit plan.
        if let credit = self.planCreditRateLimit,
           (credit.subscriptionCreditLeftRate?.value ?? 0) > 0
        {
            let fiveHourZero = (self.fiveHourUsageLeftRate?.value ?? 1) == 0
            let weeklyZero = (self.weeklyUsageLeftRate?.value ?? 1) == 0
            let fiveHourNoReset = (self.fiveHourUsageResetTime?.value ?? 0) == 0
            let weeklyNoReset = (self.weeklyUsageResetTime?.value ?? 0) == 0
            if (fiveHourZero && fiveHourNoReset) || (weeklyZero && weeklyNoReset) {
                return true
            }
        }
        return false
    }
}

/// The `plan_credit_rate_limit` object returned for credit-based plans.
public struct StepFunPlanCreditRateLimit: Decodable, Sendable {
    public let subscriptionCreditLeftRate: StepFunFlexibleNumber?
    public let subscriptionCreditResetTime: StepFunFlexibleTimestamp?
    public let topupCreditLeftRate: StepFunFlexibleNumber?
    public let creditBuckets: [StepFunPlanCreditBucket]?

    enum CodingKeys: String, CodingKey {
        case subscriptionCreditLeftRate = "subscription_credit_left_rate"
        case subscriptionCreditResetTime = "subscription_credit_reset_time"
        case topupCreditLeftRate = "topup_credit_left_rate"
        case creditBuckets = "credit_buckets"
    }

    /// Combined remaining fraction across subscription + top-up credits.
    var totalCreditLeftRate: Double? {
        // Subscription and top-up rates are independent fractions, so adding them
        // does not produce a combined rate. Prefer the absolute bucket balances.
        if let buckets = creditBuckets, !buckets.isEmpty {
            let balances = buckets.compactMap { bucket -> (total: Double, residual: Double)? in
                guard let total = bucket.creditTotal?.value,
                      let residual = bucket.creditResidual?.value,
                      total.isFinite,
                      residual.isFinite,
                      total > 0,
                      residual >= 0,
                      residual <= total
                else { return nil }
                return (total, residual)
            }
            if balances.count == buckets.count {
                let total = balances.reduce(0.0) { $0 + $1.total }
                let residual = balances.reduce(0.0) { $0 + $1.residual }
                return residual / total
            }
        }

        // Without bucket sizes there is no sound way to weight both rates. The
        // subscription balance is the primary plan allowance; use top-up only
        // when no subscription rate is present.
        return self.subscriptionCreditLeftRate?.value ?? self.topupCreditLeftRate?.value
    }
}

public struct StepFunPlanCreditBucket: Decodable, Sendable {
    public let creditTotal: StepFunFlexibleNumber?
    public let creditResidual: StepFunFlexibleNumber?
    public let expireAt: StepFunFlexibleTimestamp?
    public let nextResetAt: StepFunFlexibleTimestamp?

    enum CodingKeys: String, CodingKey {
        case creditTotal = "credit_total"
        case creditResidual = "credit_residual"
        case expireAt = "expire_at"
        case nextResetAt = "next_reset_at"
    }
}

// MARK: - Plan status response types

struct StepFunPlanStatusResponse: Decodable {
    let status: Int?
    let subscription: StepFunSubscription?

    var planName: String? {
        self.subscription?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct StepFunSubscription: Decodable {
    let name: String?
    let planType: Int?
    let planStatus: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case planType = "plan_type"
        case planStatus = "status"
    }
}

// MARK: - Auth response types

struct StepFunRegisterDeviceResponse: Decodable {
    let accessToken: StepFunTokenPair?
    let refreshToken: StepFunTokenPair?
}

struct StepFunLoginResponse: Decodable {
    let accessToken: StepFunTokenPair?
    let refreshToken: StepFunTokenPair?
}

struct StepFunRefreshTokenResponse: Decodable {
    let accessToken: StepFunTokenPair?
    let refreshToken: StepFunTokenPair?
}

struct StepFunTokenPair: Decodable {
    let raw: String
}

// MARK: - Domain snapshot

public struct StepFunUsageSnapshot: Sendable {
    public let fiveHourUsageLeftRate: Double
    public let weeklyUsageLeftRate: Double
    public let fiveHourUsageResetTime: Date
    public let weeklyUsageResetTime: Date
    public let planName: String?
    public let updatedAt: Date
    public let creditLeftRate: Double?
    public let creditResetTime: Date?
    public let isCreditPlan: Bool

    public init(
        fiveHourUsageLeftRate: Double,
        weeklyUsageLeftRate: Double,
        fiveHourUsageResetTime: Date,
        weeklyUsageResetTime: Date,
        planName: String? = nil,
        updatedAt: Date,
        creditLeftRate: Double? = nil,
        creditResetTime: Date? = nil,
        isCreditPlan: Bool = false)
    {
        self.fiveHourUsageLeftRate = fiveHourUsageLeftRate
        self.weeklyUsageLeftRate = weeklyUsageLeftRate
        self.fiveHourUsageResetTime = fiveHourUsageResetTime
        self.weeklyUsageResetTime = weeklyUsageResetTime
        self.planName = planName
        self.updatedAt = updatedAt
        self.creditLeftRate = creditLeftRate
        self.creditResetTime = creditResetTime
        self.isCreditPlan = isCreditPlan
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let trimmedPlan = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (trimmedPlan?.isEmpty ?? true) ? "password" : trimmedPlan

        let identity = ProviderIdentitySnapshot(
            providerID: .stepfun,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)

        // Credit-based plans (plan_family=2) don't have 5h/weekly rate windows.
        // Show the credit balance as the primary window and drop the meaningless
        // 0%-left rate windows entirely.
        if self.isCreditPlan, let creditRate = self.creditLeftRate {
            let creditUsedPercent = max(0, min(100, (1.0 - creditRate) * 100))
            let resetDate = self.creditResetTime ?? Date.distantFuture
            let resetDescription = UsageFormatter.resetDescription(from: resetDate)
            let creditWindow = RateWindow(
                usedPercent: creditUsedPercent,
                windowMinutes: nil,
                resetsAt: resetDate,
                resetDescription: resetDescription)

            return UsageSnapshot(
                primary: creditWindow,
                secondary: nil,
                tertiary: nil,
                updatedAt: self.updatedAt,
                identity: identity)
        }

        // Rate-window plans: five-hour window as primary, weekly as secondary.
        // Five-hour window: primary
        let fiveHourUsedPercent = max(0, min(100, (1.0 - self.fiveHourUsageLeftRate) * 100))
        let fiveHourResetDescription = UsageFormatter.resetDescription(from: self.fiveHourUsageResetTime)
        let fiveHourWindow = RateWindow(
            usedPercent: fiveHourUsedPercent,
            windowMinutes: 300,
            resetsAt: self.fiveHourUsageResetTime,
            resetDescription: fiveHourResetDescription)

        // Weekly window: secondary
        let weeklyUsedPercent = max(0, min(100, (1.0 - self.weeklyUsageLeftRate) * 100))
        let weeklyResetDescription = UsageFormatter.resetDescription(from: self.weeklyUsageResetTime)
        let weeklyWindow = RateWindow(
            usedPercent: weeklyUsedPercent,
            windowMinutes: 10080,
            resetsAt: self.weeklyUsageResetTime,
            resetDescription: weeklyResetDescription)

        return UsageSnapshot(
            primary: fiveHourWindow,
            secondary: weeklyWindow,
            tertiary: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

// MARK: - Errors

public enum StepFunUsageError: LocalizedError, Sendable {
    case missingCredentials
    case missingToken
    case networkError(String)
    case apiError(String)
    case parseFailed(String)
    case loginFailed(String)
    case tokenRefreshFailed(String)
    case deviceRegistrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing StepFun username or password. Set STEPFUN_USERNAME and STEPFUN_PASSWORD environment variables."
        case .missingToken:
            "Missing StepFun authentication token."
        case let .networkError(message):
            "StepFun network error: \(message)"
        case let .apiError(message):
            "StepFun API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse StepFun response: \(message)"
        case let .loginFailed(message):
            "StepFun login failed: \(message)"
        case let .tokenRefreshFailed(message):
            "StepFun token refresh failed: \(message)"
        case let .deviceRegistrationFailed(message):
            "StepFun device registration failed: \(message)"
        }
    }
}

// MARK: - Fetcher

public struct StepFunUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.stepfunUsage)
    private static let platformURL = URL(string: "https://platform.stepfun.com")!
    private static let apiURL =
        URL(string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit")!
    private static let planStatusURL =
        URL(string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus")!
    private static let registerDeviceURL =
        URL(string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/RegisterDevice")!
    private static let loginURL =
        URL(string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/SignInByPassword")!
    private static let refreshTokenURL =
        URL(string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/RefreshToken")!
    private static let timeoutSeconds: TimeInterval = 15

    /// Fallback webid used only for the initial device-registration / login flow,
    /// before we have a token to derive the real device_id from.
    private static let defaultWebID = "c8a1002d2c457e758785a9979832217c7c0b884c"
    private static let appID = "10300"

    private static let baseHeaders: [String: String] = [
        "content-type": "application/json",
        "oasis-appid": appID,
        "oasis-platform": "web",
        "oasis-webid": defaultWebID,
        "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36",
    ]

    /// Extract the `device_id` from a token's JWT payload to use as the Oasis-Webid.
    /// The refresh-token half of the "access...refresh" pair carries a `device_id`
    /// claim that must match the Oasis-Webid header/cookie, otherwise the server
    /// returns "auth failed: oasis-token is embezzled".
    private static func webID(forToken token: String) -> String {
        // The token is either a bare JWT or an "access...refresh" pair.
        // The device_id lives in the refresh half; fall back to the access half.
        let halves = token.components(separatedBy: "...")
        for half in halves.reversed() {
            if let webid = Self.extractDeviceID(from: half), !webid.isEmpty {
                return webid
            }
        }
        return Self.defaultWebID
    }

    /// Decode the JWT payload (without signature verification) and return `device_id`.
    private static func extractDeviceID(from jwt: String) -> String? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1]
        // base64url padding
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
            of: "_",
            with: "/")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["device_id"] as? String
    }

    // MARK: - Public API

    /// Perform the full login flow (username + password → Oasis-Token) and return the token.
    /// Does NOT fetch usage — the caller should cache the token and then call `fetchUsage(token:)`.
    public static func login(username: String, password: String) async throws -> String {
        try await self.fullLogin(username: username, password: password)
    }

    /// Refresh an existing Oasis-Token and return a fresh access + refresh token pair.
    public static func refreshToken(token: String) async throws -> String {
        try await self.refreshOasisToken(token: token)
    }

    /// Fetch usage data using an existing Oasis-Token (from env var or cached).
    public static func fetchUsage(token: String) async throws -> StepFunUsageSnapshot {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StepFunUsageError.missingToken
        }
        return try await self.queryUsage(token: token)
    }

    /// Full login flow: username + password → token, then fetch usage.
    public static func fetchUsage(username: String, password: String) async throws -> StepFunUsageSnapshot {
        let token = try await self.fullLogin(username: username, password: password)
        return try await self.queryUsage(token: token)
    }

    // MARK: - Login

    private static func fullLogin(username: String, password: String) async throws -> String {
        // Step 1: Get INGRESSCOOKIE by visiting the platform homepage
        let (ingressCookie, _) = try await self.getIngressCookie()

        // Step 2: RegisterDevice → get anonymous token
        let anonToken = try await self.registerDevice(ingressCookie: ingressCookie)

        // Step 3: SignInByPassword → get authenticated token
        return try await self.signInByPassword(
            username: username,
            password: password,
            ingressCookie: ingressCookie,
            anonToken: anonToken)
    }

    private static func getIngressCookie() async throws -> (String, HTTPURLResponse) {
        var request = URLRequest(url: self.platformURL)
        request.httpMethod = "GET"
        for (key, value) in self.baseHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.timeoutInterval = self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let httpResponse = response.response

        // Extract INGRESSCOOKIE from Set-Cookie headers
        let setCookieHeaders = httpResponse.allHeaderFields.filter { ($0.key as? String)?.lowercased() == "set-cookie" }
        var ingressCookie = ""
        for (_, value) in setCookieHeaders {
            let cookieString = "\(value)"
            if cookieString.contains("INGRESSCOOKIE=") {
                let parts = cookieString.components(separatedBy: "INGRESSCOOKIE=")
                if parts.count > 1 {
                    let valuePart = parts[1].components(separatedBy: ";").first ?? ""
                    ingressCookie = valuePart.trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // Also check cookies from the URLSession cookie store
        if ingressCookie.isEmpty {
            let cookies = HTTPCookieStorage.shared.cookies(for: self.platformURL) ?? []
            for cookie in cookies where cookie.name == "INGRESSCOOKIE" {
                ingressCookie = cookie.value
                break
            }
        }

        guard !ingressCookie.isEmpty else {
            throw StepFunUsageError.loginFailed("Could not obtain INGRESSCOOKIE")
        }

        return (ingressCookie, httpResponse)
    }

    private static func registerDevice(ingressCookie: String) async throws -> String {
        var request = URLRequest(url: self.registerDeviceURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        for (key, value) in self.baseHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("INGRESSCOOKIE=\(ingressCookie)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("StepFun RegisterDevice returned \(response.statusCode): \(body)")
            throw StepFunUsageError.deviceRegistrationFailed("HTTP \(response.statusCode)")
        }

        let decoded: StepFunRegisterDeviceResponse
        do {
            decoded = try JSONDecoder().decode(StepFunRegisterDeviceResponse.self, from: data)
        } catch {
            throw StepFunUsageError.parseFailed("RegisterDevice response: \(error.localizedDescription)")
        }

        guard let accessToken = decoded.accessToken?.raw, !accessToken.isEmpty else {
            throw StepFunUsageError.deviceRegistrationFailed("No access token in RegisterDevice response")
        }

        return self.combinedToken(accessToken: accessToken, refreshToken: decoded.refreshToken?.raw)
    }

    private static func signInByPassword(
        username: String,
        password: String,
        ingressCookie: String,
        anonToken: String) async throws -> String
    {
        var request = URLRequest(url: self.loginURL)
        request.httpMethod = "POST"
        let body: [String: String] = ["username": username, "password": password]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        for (key, value) in self.baseHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let webid = Self.webID(forToken: anonToken)
        request.setValue(webid, forHTTPHeaderField: "oasis-webid")
        request.setValue(
            "Oasis-Token=\(anonToken); Oasis-Webid=\(webid); INGRESSCOOKIE=\(ingressCookie)",
            forHTTPHeaderField: "Cookie")
        request.timeoutInterval = self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("StepFun SignInByPassword returned \(response.statusCode): \(body)")
            throw StepFunUsageError.loginFailed("HTTP \(response.statusCode)")
        }

        let decoded: StepFunLoginResponse
        do {
            decoded = try JSONDecoder().decode(StepFunLoginResponse.self, from: data)
        } catch {
            throw StepFunUsageError.parseFailed("SignInByPassword response: \(error.localizedDescription)")
        }

        guard let accessToken = decoded.accessToken?.raw, !accessToken.isEmpty else {
            throw StepFunUsageError.loginFailed("No access token in login response")
        }

        return self.combinedToken(accessToken: accessToken, refreshToken: decoded.refreshToken?.raw)
    }

    private static func refreshOasisToken(token: String) async throws -> String {
        let normalized = StepFunTokenNormalizer.normalize(token)
        guard !normalized.isEmpty else {
            throw StepFunUsageError.missingToken
        }
        let webid = Self.webID(forToken: normalized)

        var request = URLRequest(url: self.refreshTokenURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        for (key, value) in self.baseHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(webid, forHTTPHeaderField: "oasis-webid")
        request.setValue(normalized, forHTTPHeaderField: "Oasis-Token")
        request.setValue(
            "Oasis-Token=\(normalized); Oasis-Webid=\(webid)",
            forHTTPHeaderField: "Cookie")
        request.timeoutInterval = self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("StepFun RefreshToken returned \(response.statusCode): \(body)")
            throw StepFunUsageError.tokenRefreshFailed("HTTP \(response.statusCode)")
        }

        let decoded: StepFunRefreshTokenResponse
        do {
            decoded = try JSONDecoder().decode(StepFunRefreshTokenResponse.self, from: data)
        } catch {
            throw StepFunUsageError.parseFailed("RefreshToken response: \(error.localizedDescription)")
        }

        guard let accessToken = decoded.accessToken?.raw, !accessToken.isEmpty else {
            throw StepFunUsageError.tokenRefreshFailed("No access token in refresh response")
        }

        return self.combinedToken(accessToken: accessToken, refreshToken: decoded.refreshToken?.raw)
    }

    private static func combinedToken(accessToken: String, refreshToken: String?) -> String {
        guard let refreshToken, !refreshToken.isEmpty else {
            return accessToken
        }
        return "\(accessToken)...\(refreshToken)"
    }

    // MARK: - Query usage

    private static func queryUsage(token: String) async throws -> StepFunUsageSnapshot {
        let webid = Self.webID(forToken: token)
        var request = URLRequest(url: self.apiURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        for (key, value) in self.baseHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Override the header webid with the one matching this token's device_id.
        request.setValue(webid, forHTTPHeaderField: "oasis-webid")
        request.setValue("Oasis-Token=\(token); Oasis-Webid=\(webid)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("StepFun API returned \(response.statusCode): \(body)")
            throw StepFunUsageError.apiError("HTTP \(response.statusCode)")
        }

        if let jsonString = String(data: data, encoding: .utf8) {
            Self.log.debug("StepFun API response: \(jsonString)")
        }

        var snapshot = try self.parseSnapshot(data: data)

        // Fetch plan name in parallel is not needed — just do it sequentially.
        // If plan status fails, we still return usage data without plan name.
        if let planName = try? await self.queryPlanStatus(token: token) {
            snapshot = StepFunUsageSnapshot(
                fiveHourUsageLeftRate: snapshot.fiveHourUsageLeftRate,
                weeklyUsageLeftRate: snapshot.weeklyUsageLeftRate,
                fiveHourUsageResetTime: snapshot.fiveHourUsageResetTime,
                weeklyUsageResetTime: snapshot.weeklyUsageResetTime,
                planName: planName,
                updatedAt: snapshot.updatedAt,
                creditLeftRate: snapshot.creditLeftRate,
                creditResetTime: snapshot.creditResetTime,
                isCreditPlan: snapshot.isCreditPlan)
        }

        return snapshot
    }

    // MARK: - Plan Status

    private static func queryPlanStatus(token: String) async throws -> String? {
        let webid = Self.webID(forToken: token)
        var request = URLRequest(url: self.planStatusURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        for (key, value) in self.baseHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(webid, forHTTPHeaderField: "oasis-webid")
        request.setValue("Oasis-Token=\(token); Oasis-Webid=\(webid)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = self.timeoutSeconds

        let response = try await ProviderHTTPClient.shared.response(for: request)
        guard response.statusCode == 200 else {
            Self.log.debug("StepFun plan status request failed, skipping plan name")
            return nil
        }

        let decoded: StepFunPlanStatusResponse
        do {
            decoded = try JSONDecoder().decode(StepFunPlanStatusResponse.self, from: response.data)
        } catch {
            Self.log.debug("StepFun plan status parse failed: \(error.localizedDescription)")
            return nil
        }

        return decoded.planName
    }

    public static func _parseSnapshotForTesting(_ data: Data) throws -> StepFunUsageSnapshot {
        try self.parseSnapshot(data: data)
    }

    private static func parseSnapshot(data: Data) throws -> StepFunUsageSnapshot {
        let decoded: StepFunRateLimitResponse
        do {
            decoded = try JSONDecoder().decode(StepFunRateLimitResponse.self, from: data)
        } catch {
            throw StepFunUsageError.parseFailed(error.localizedDescription)
        }

        guard decoded.isSuccess else {
            let msg = [decoded.message, decoded.desc]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? decoded.code.map(String.init) ?? "unknown"
            throw StepFunUsageError.apiError(msg)
        }

        // Credit-based plans (plan_family=2) don't populate the rate-window fields
        // meaningfully, so don't require them. Fall back to 0/epoch if absent.
        let fiveHourRate = decoded.fiveHourUsageLeftRate?.value ?? 0
        let weeklyRate = decoded.weeklyUsageLeftRate?.value ?? 0
        let fiveHourReset = decoded.fiveHourUsageResetTime?.value ?? 0
        let weeklyReset = decoded.weeklyUsageResetTime?.value ?? 0

        // For non-credit plans, require the rate fields to be present.
        if !decoded.isCreditPlan {
            guard decoded.fiveHourUsageLeftRate != nil,
                  decoded.weeklyUsageLeftRate != nil,
                  decoded.fiveHourUsageResetTime != nil,
                  decoded.weeklyUsageResetTime != nil
            else {
                throw StepFunUsageError.parseFailed("Missing usage rate or reset time fields")
            }
        }

        let creditLeftRate = decoded.planCreditRateLimit?.totalCreditLeftRate
        let creditResetTime = decoded.planCreditRateLimit?.subscriptionCreditResetTime
            .map { Date(timeIntervalSince1970: TimeInterval($0.value)) }

        return StepFunUsageSnapshot(
            fiveHourUsageLeftRate: fiveHourRate,
            weeklyUsageLeftRate: weeklyRate,
            fiveHourUsageResetTime: Date(timeIntervalSince1970: TimeInterval(fiveHourReset)),
            weeklyUsageResetTime: Date(timeIntervalSince1970: TimeInterval(weeklyReset)),
            updatedAt: Date(),
            creditLeftRate: creditLeftRate,
            creditResetTime: creditResetTime,
            isCreditPlan: decoded.isCreditPlan)
    }
}
