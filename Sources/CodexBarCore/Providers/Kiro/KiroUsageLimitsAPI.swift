import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// Kiro credit usage read from the service the official CLI itself calls.
///
/// The CLI's `/usage` report states credits against the plan alone and omits the overage section
/// entirely for organization accounts, so it can never show how much overage has been spent or how
/// much remains. `GetUsageLimits` carries the overage allowance on top of the plan, which is the
/// ceiling an account actually spends against.
public struct KiroUsageLimits: Equatable, Sendable {
    /// Credits included in the plan.
    public let planLimit: Double
    /// Plan credits spent, excluding overage.
    public let planUsed: Double
    /// Overage credits spent beyond the plan.
    public let overageUsed: Double
    /// Maximum overage credits the account may spend, or nil when overage is not enabled.
    public let overageCap: Double?
    /// `true`/`false` when the API stated ENABLED/DISABLED; `nil` when omitted, unrecognized, or ENABLED without a cap.
    public let overageEnabled: Bool?
    /// Charges accrued for `overageUsed`, in `currencyCode`.
    public let overageCharges: Double?
    /// Price per overage credit, in `currencyCode`.
    public let overageRate: Double?
    public let currencyCode: String
    public let resetsAt: Date
    /// True when `bonuses[]` was non-empty, so plan usage cannot be split from bonus spend.
    public let hasUnseparatedBonus: Bool

    public init(
        planLimit: Double,
        planUsed: Double,
        overageUsed: Double,
        overageCap: Double?,
        overageEnabled: Bool? = nil,
        overageCharges: Double?,
        overageRate: Double?,
        currencyCode: String,
        resetsAt: Date,
        hasUnseparatedBonus: Bool = false)
    {
        self.planLimit = planLimit
        self.planUsed = planUsed
        self.overageUsed = overageUsed
        self.overageCap = overageCap
        self.overageEnabled = overageEnabled
        self.overageCharges = overageCharges
        self.overageRate = overageRate
        self.currencyCode = currencyCode
        self.resetsAt = resetsAt
        self.hasUnseparatedBonus = hasUnseparatedBonus
    }

    /// The overage budget in currency terms, used as the denominator for accrued charges.
    public var overageChargeLimit: Double? {
        guard let overageCap, let overageRate, overageCap > 0, overageRate > 0 else { return nil }
        return overageCap * overageRate
    }
}

public enum KiroUsageLimitsError: LocalizedError, Sendable {
    case credentialsUnavailable(String)
    case requestFailed(String)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case let .credentialsUnavailable(message):
            "Kiro CLI credentials unavailable: \(message)"
        case let .requestFailed(message):
            "Kiro usage API request failed: \(message)"
        case let .parseError(message):
            "Failed to parse Kiro usage API response: \(message)"
        }
    }
}

public enum KiroUsageLimitsAPI: Sendable {
    /// Endpoint the official CLI resolves for `codewhispererruntime`.
    static let defaultEndpoint = URL(string: "https://codewhisperer.us-east-1.amazonaws.com/")!
    private static let target = "AmazonCodeWhispererService.GetUsageLimits"
    private static let contentType = "application/x-amz-json-1.0"
    private static let creditResource = "CREDIT"
    private static let overageEnabled = "ENABLED"
    private static let overageDisabled = "DISABLED"
    private static let requestTimeout: TimeInterval = 10
    /// Plausible Unix seconds for a billing reset: 2001-09-09 through 2100-01-01. A value outside
    /// this range is a unit change, not a date — milliseconds would land far beyond any real reset.
    private static let resetRange: ClosedRange<Double> = 1_000_000_000...4_102_444_800

    private static let logger = CodexBarLog.logger(LogCategories.provider(.kiro, scope: "usage-api"))

    public static func stateDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        usesMacOSApplicationSupport: Bool = {
            #if os(macOS)
            true
            #else
            false
            #endif
        }()) -> URL
    {
        if let override = self.cleanedPath(environment["KIRO_DATA_DIR"]) {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("data.sqlite3", isDirectory: false)
        }
        if usesMacOSApplicationSupport {
            return homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("kiro-cli", isDirectory: true)
                .appendingPathComponent("data.sqlite3", isDirectory: false)
        }
        let dataHome = self.cleanedPath(environment["XDG_DATA_HOME"]).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
        return dataHome
            .appendingPathComponent("kiro-cli", isDirectory: true)
            .appendingPathComponent("data.sqlite3", isDirectory: false)
    }

    private static func cleanedPath(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return (trimmed as NSString).expandingTildeInPath
    }

    public static func fetch(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> KiroUsageLimits
    {
        try await self.fetch(
            databaseURL: self.stateDatabaseURL(homeDirectory: homeDirectory),
            endpoint: self.defaultEndpoint,
            transport: self.isolatedTransport)
    }

    static func fetch(
        databaseURL: URL,
        endpoint: URL,
        transport: any ProviderHTTPTransport) async throws -> KiroUsageLimits
    {
        let identity = try self.readIdentity(databaseURL: databaseURL)
        var request = URLRequest(url: endpoint, timeoutInterval: self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue(self.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(self.target, forHTTPHeaderField: "X-Amz-Target")
        request.setValue("Bearer \(identity.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["profileArn": identity.profileARN])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw KiroUsageLimitsError.requestFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw KiroUsageLimitsError.requestFailed("HTTP \(http.statusCode)")
        }
        return try self.parse(data)
    }

    static func parse(_ data: Data) throws -> KiroUsageLimits {
        let response: UsageLimitsResponse
        do {
            response = try JSONDecoder().decode(UsageLimitsResponse.self, from: data)
        } catch {
            throw KiroUsageLimitsError.parseError(error.localizedDescription)
        }

        let credits = response.usageBreakdownList.filter { $0.resourceType == self.creditResource }
        guard let credit = credits.first else {
            throw KiroUsageLimitsError.parseError("no credit balance reported")
        }
        guard credits.count == 1 else {
            throw KiroUsageLimitsError.parseError("several credit balances reported")
        }

        // Validate each component rather than the sum: a negative one would otherwise hide inside a
        // positive total and produce an authoritative wrong percentage.
        let planLimit = try self.usableCredits(credit.usageLimitWithPrecision, field: "plan limit")
        let totalUsed = try self.usableCredits(credit.currentUsageWithPrecision, field: "usage")
        let overageUsed = try self.usableCredits(
            credit.currentOveragesWithPrecision ?? 0,
            field: "overage usage")
        // `currentUsage` is the total including overage. An overage larger than that total is
        // relationally impossible, and clamping it to zero would overwrite valid CLI plan usage.
        guard totalUsed >= overageUsed else {
            throw KiroUsageLimitsError.parseError("overage exceeds total usage")
        }
        let planUsed = totalUsed - overageUsed
        let hasUnseparatedBonus = !(credit.bonuses ?? []).isEmpty
        // Bonus spend is folded into currentUsage, so planUsed can exceed the plan ceiling.
        if !hasUnseparatedBonus {
            guard planUsed <= planLimit else {
                throw KiroUsageLimitsError.parseError("plan usage exceeds plan limit")
            }
        }

        let overageAvailability = self.overageAvailability(response.overageConfiguration?.overageStatus)
        let overageCap: Double? = if overageAvailability == true, let cap = credit.overageCapWithPrecision {
            try self.usableCredits(cap, field: "overage cap")
        } else {
            nil
        }
        // ENABLED without a cap is incomplete, not disabled — keep CLI overage rows visible.
        let overageEnabled: Bool? = overageAvailability == true && overageCap == nil ? nil : overageAvailability
        guard let resetsAt = self.resetDate(credit.nextDateReset ?? response.nextDateReset) else {
            throw KiroUsageLimitsError.parseError("no plausible reset date reported")
        }

        return KiroUsageLimits(
            planLimit: planLimit,
            planUsed: planUsed,
            overageUsed: overageUsed,
            overageCap: overageCap,
            overageEnabled: overageEnabled,
            overageCharges: credit.overageCharges.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            overageRate: credit.overageRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            currencyCode: credit.currency ?? "USD",
            resetsAt: resetsAt,
            hasUnseparatedBonus: hasUnseparatedBonus)
    }

    private static func overageAvailability(_ status: String?) -> Bool? {
        guard let status, !status.isEmpty else { return nil }
        switch status.uppercased() {
        case self.overageEnabled:
            return true
        case self.overageDisabled:
            return false
        default:
            return nil
        }
    }

    private static func usableCredits(_ value: Double, field: String) throws -> Double {
        guard value.isFinite, value >= 0 else {
            throw KiroUsageLimitsError.parseError("no usable \(field)")
        }
        return value
    }

    private static func resetDate(_ value: Double?) -> Date? {
        guard let value, value.isFinite, self.resetRange.contains(value) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private static let isolatedTransport: any ProviderHTTPTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return ProviderHTTPClient(session: ProviderHTTPClient.redirectGuardedSession(configuration: configuration))
    }()

    // MARK: - Response shape

    private struct UsageLimitsResponse: Decodable {
        let usageBreakdownList: [UsageBreakdown]
        let overageConfiguration: OverageConfiguration?
        let nextDateReset: Double?
    }

    private struct UsageBreakdown: Decodable {
        let resourceType: String
        let currentUsageWithPrecision: Double
        let usageLimitWithPrecision: Double
        let currentOveragesWithPrecision: Double?
        let overageCapWithPrecision: Double?
        let overageCharges: Double?
        let overageRate: Double?
        let currency: String?
        let nextDateReset: Double?
        let bonuses: [BonusEntry]?

        struct BonusEntry: Decodable {}
    }

    private struct OverageConfiguration: Decodable {
        let overageStatus: String
    }

    // MARK: - CLI credentials

    private struct KiroCLIIdentity {
        let accessToken: String
        let profileARN: String
    }

    /// Reads the CLI's credentials without disturbing them: the CLI owns the token and its refresh,
    /// so this connection is read-only.
    ///
    /// A test that reaches this without opting in would resolve the developer's real state database
    /// and call the live service with their token, so tests must name their own database instead.
    private static func readIdentity(databaseURL: URL) throws -> KiroCLIIdentity {
        #if canImport(SQLite3) || canImport(CSQLite3)
        if ProviderHTTPClient.isRunningTests, databaseURL == self.stateDatabaseURL() {
            throw KiroUsageLimitsError.credentialsUnavailable(
                "usage API needs an explicit state database under tests")
        }
        guard FileManager.default.isReadableFile(atPath: databaseURL.path) else {
            throw KiroUsageLimitsError.credentialsUnavailable("Kiro CLI state database not readable")
        }
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw KiroUsageLimitsError.credentialsUnavailable("open state database: \(message)")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let tokenJSON = try self.queryValue(
            db: db,
            sql: "SELECT value FROM auth_kv WHERE key = 'kirocli:odic:token'",
            what: "token")
        let profileJSON = try self.queryValue(
            db: db,
            sql: "SELECT value FROM state WHERE key = 'api.codewhisperer.profile'",
            what: "profile")

        guard let accessToken = self.jsonString(in: tokenJSON, key: "access_token") else {
            throw KiroUsageLimitsError.credentialsUnavailable("token has no access_token")
        }
        guard let profileARN = self.jsonString(in: profileJSON, key: "arn") else {
            throw KiroUsageLimitsError.credentialsUnavailable("profile has no arn")
        }
        return KiroCLIIdentity(accessToken: accessToken, profileARN: profileARN)
        #else
        throw KiroUsageLimitsError.credentialsUnavailable("SQLite unavailable on this platform")
        #endif
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func queryValue(db: OpaquePointer?, sql: String, what: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw KiroUsageLimitsError.credentialsUnavailable("read \(what): \(message)")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            throw KiroUsageLimitsError.credentialsUnavailable("\(what) not found in Kiro CLI state")
        }
        return String(cString: text)
    }
    #endif

    private static func jsonString(in json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String,
              !value.isEmpty
        else { return nil }
        return value
    }
}
