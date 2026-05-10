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

    enum CodingKeys: String, CodingKey {
        case status
        case code
        case message
        case desc
        case fiveHourUsageLeftRate = "five_hour_usage_left_rate"
        case weeklyUsageLeftRate = "weekly_usage_left_rate"
        case fiveHourUsageResetTime = "five_hour_usage_reset_time"
        case weeklyUsageResetTime = "weekly_usage_reset_time"
    }

    public var isSuccess: Bool {
        self.status == 1
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

    public init(
        fiveHourUsageLeftRate: Double,
        weeklyUsageLeftRate: Double,
        fiveHourUsageResetTime: Date,
        weeklyUsageResetTime: Date,
        planName: String? = nil,
        updatedAt: Date)
    {
        self.fiveHourUsageLeftRate = fiveHourUsageLeftRate
        self.weeklyUsageLeftRate = weeklyUsageLeftRate
        self.fiveHourUsageResetTime = fiveHourUsageResetTime
        self.weeklyUsageResetTime = weeklyUsageResetTime
        self.planName = planName
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
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

        let trimmedPlan = self.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let loginMethod = (trimmedPlan?.isEmpty ?? true) ? "password" : trimmedPlan

        let identity = ProviderIdentitySnapshot(
            providerID: .stepfun,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: loginMethod)

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
    private static let timeoutSeconds: TimeInterval = 15

    private static let webID = "c8a1002d2c457e758785a9979832217c7c0b884c"
    private static let appID = "10300"

    private static let baseHeaders: [String: String] = [
        "content-type": "application/json",
        "oasis-appid": appID,
        "oasis-platform": "web",
        "oasis-webid": webID,
        "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36",
    ]

    // MARK: - Public API

    /// Perform the full login flow (username + password → Oasis-Token) and return the token.
    /// Does NOT fetch usage — the caller should cache the token and then call `fetchUsage(token:)`.
    public static func login(username: String, password: String) async throws -> String {
        try await self.fullLogin(username: username, password: password)
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

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StepFunUsageError.networkError("Invalid response fetching platform page")
        }

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

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StepFunUsageError.networkError("Invalid response from RegisterDevice")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("StepFun RegisterDevice returned \(httpResponse.statusCode): \(body)")
            throw StepFunUsageError.deviceRegistrationFailed("HTTP \(httpResponse.statusCode)")
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

        let refreshToken = decoded.refreshToken?.raw ?? ""
        // Combine access + refresh tokens like the Python tool does
        return "\(accessToken)...\(refreshToken)"
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
        request.setValue(
            "Oasis-Token=\(anonToken); Oasis-Webid=\(self.webID); INGRESSCOOKIE=\(ingressCookie)",
            forHTTPHeaderField: "Cookie")
        request.timeoutInterval = self.timeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StepFunUsageError.networkError("Invalid response from SignInByPassword")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("StepFun SignInByPassword returned \(httpResponse.statusCode): \(body)")
            throw StepFunUsageError.loginFailed("HTTP \(httpResponse.statusCode)")
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

        let refreshToken = decoded.refreshToken?.raw ?? ""
        return "\(accessToken)...\(refreshToken)"
    }

    // MARK: - Query usage

    private static func queryUsage(token: String) async throws -> StepFunUsageSnapshot {
        var request = URLRequest(url: self.apiURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        for (key, value) in self.baseHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("Oasis-Token=\(token); Oasis-Webid=\(self.webID)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = self.timeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StepFunUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("StepFun API returned \(httpResponse.statusCode): \(body)")
            throw StepFunUsageError.apiError("HTTP \(httpResponse.statusCode)")
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
                updatedAt: snapshot.updatedAt)
        }

        return snapshot
    }

    // MARK: - Plan Status

    private static func queryPlanStatus(token: String) async throws -> String? {
        var request = URLRequest(url: self.planStatusURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        for (key, value) in self.baseHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("Oasis-Token=\(token); Oasis-Webid=\(self.webID)", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = self.timeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            Self.log.debug("StepFun plan status request failed, skipping plan name")
            return nil
        }

        let decoded: StepFunPlanStatusResponse
        do {
            decoded = try JSONDecoder().decode(StepFunPlanStatusResponse.self, from: data)
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
            let msg = decoded.message ?? decoded.code.map(String.init) ?? "unknown"
            throw StepFunUsageError.apiError(msg)
        }

        guard let fiveHourRate = decoded.fiveHourUsageLeftRate,
              let weeklyRate = decoded.weeklyUsageLeftRate,
              let fiveHourReset = decoded.fiveHourUsageResetTime,
              let weeklyReset = decoded.weeklyUsageResetTime
        else {
            throw StepFunUsageError.parseFailed("Missing usage rate or reset time fields")
        }

        return StepFunUsageSnapshot(
            fiveHourUsageLeftRate: fiveHourRate.value,
            weeklyUsageLeftRate: weeklyRate.value,
            fiveHourUsageResetTime: Date(timeIntervalSince1970: TimeInterval(fiveHourReset.value)),
            weeklyUsageResetTime: Date(timeIntervalSince1970: TimeInterval(weeklyReset.value)),
            updatedAt: Date())
    }
}
