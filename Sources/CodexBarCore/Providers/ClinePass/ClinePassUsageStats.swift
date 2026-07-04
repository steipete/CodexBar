import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Wire DTOs

// Cline wraps successful responses in a `{ success, data, error }` envelope
// (see the open-source `ClineAccountService`). ClinePass is a flat-rate
// subscription whose limits are three rolling windows. CodexBar reads:
//   GET /api/v1/users/me                    -> { email }
//   GET /api/v1/users/me/plan               -> plan.displayName
//   GET /api/v1/users/me/plan/usage-limits  -> { limits: [{ type, percentUsed, resetsAt }] }
// The /plan and /plan/usage-limits endpoints are NOT in Cline's published
// Enterprise API Reference (which only documents /users/me, /users/{id}/balance,
// /users/{id}/usages, and /organizations/{orgId}/plan). They were extracted from
// the Cline web dashboard's own JavaScript bundle and verified against the live
// api.cline.bot. The usage-limits endpoint returns server-computed utilization
// per window (five_hour / weekly / monthly), so CodexBar maps each directly to a
// rate window. If /plan/usage-limits is unavailable, the fetch degrades to
// showing the plan name + account email without usage windows.

/// Generic Cline API success envelope.
struct ClinePassEnvelope<T: Decodable>: Decodable {
    let success: Bool?
    let error: String?
    let data: T?
}

/// `GET /api/v1/users/me` payload. Only `email` is consumed; the response also
/// carries `id` and `active_account_id` (personal vs org), but CodexBar's
/// ClinePass read path uses the literal `me` segment for every endpoint, so
/// neither id is needed to build downstream URLs.
struct ClinePassUserDTO: Decodable {
    let email: String?
}

/// `GET /api/v1/users/me/plan` payload (the `data` object). Only the plan name
/// is used; caps come from the usage-limits endpoint.
struct ClinePassPlanDTO: Decodable {
    struct Plan: Decodable {
        let displayName: String?
    }

    let plan: Plan?
}

/// `GET /api/v1/users/me/plan/usage-limits` payload (the `data` object).
struct ClinePassUsageLimitsDTO: Decodable {
    struct Limit: Decodable {
        let type: String
        let percentUsed: Double?
        let resetsAt: String?
    }

    let limits: [Limit]
}

// MARK: - Snapshot (persisted in UsageSnapshot)

/// One ClinePass rolling usage window: percentage of the cap used, plus its
/// rolling reset time.
public struct ClinePassWindow: Codable, Sendable, Equatable {
    public let percentUsed: Double
    public let resetsAt: Date?

    public init(percentUsed: Double, resetsAt: Date?) {
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
    }
}

/// ClinePass usage snapshot: the three server-computed rolling windows plus plan
/// name and account email.
public struct ClinePassUsageSnapshot: Codable, Sendable, Equatable {
    public let planName: String?
    public let accountEmail: String?
    public let fiveHour: ClinePassWindow?
    public let weekly: ClinePassWindow?
    public let monthly: ClinePassWindow?
    public let updatedAt: Date

    public init(
        planName: String?,
        accountEmail: String?,
        fiveHour: ClinePassWindow?,
        weekly: ClinePassWindow?,
        monthly: ClinePassWindow?,
        updatedAt: Date)
    {
        self.planName = planName
        self.accountEmail = accountEmail
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.monthly = monthly
        self.updatedAt = updatedAt
    }

    /// Whether any usage window was resolved (a real ClinePass entitlement).
    public var hasWindows: Bool {
        self.fiveHour != nil || self.weekly != nil || self.monthly != nil
    }
}

extension ClinePassUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .clinepass,
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.planName)

        return UsageSnapshot(
            primary: self.fiveHour.map { Self.rateWindow($0, windowMinutes: 5 * 60) },
            secondary: self.weekly.map { Self.rateWindow($0, windowMinutes: 7 * 24 * 60) },
            tertiary: self.monthly.map { Self.rateWindow($0, windowMinutes: 30 * 24 * 60) },
            clinePassUsage: self,
            updatedAt: self.updatedAt,
            identity: identity,
            dataConfidence: .exact)
    }

    private static func rateWindow(_ window: ClinePassWindow, windowMinutes: Int) -> RateWindow {
        RateWindow(
            usedPercent: min(100, max(0, window.percentUsed)),
            windowMinutes: windowMinutes,
            resetsAt: window.resetsAt,
            resetDescription: nil)
    }
}

// MARK: - Fetcher

/// Fetches the three server-computed ClinePass usage windows from the Cline
/// account API (the same data the Cline web dashboard shows).
public struct ClinePassUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.clinePassUsage)
    private static let requestTimeoutSeconds: TimeInterval = 15
    private static let maxErrorBodyLength = 240

    /// One concurrently-fetched part of the account read.
    private enum FetchPart: Sendable {
        case user(ClinePassUserDTO)
        case plan(ClinePassPlanDTO)
        case limits(ClinePassUsageLimitsDTO?)
    }

    /// Fetches account identity, plan name, and windowed usage using the API key.
    ///
    /// Fires all three reads concurrently. `/users/me` and `/users/me/plan` are
    /// required; `/users/me/plan/usage-limits` is best-effort — that endpoint is
    /// dashboard-derived (not in Cline's published API reference), so a 404 or
    /// transient failure degrades to showing the plan name + account email
    /// without usage windows rather than failing the whole fetch.
    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> ClinePassUsageSnapshot
    {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClinePassUsageError.invalidCredentials
        }
        try ClinePassSettingsReader.validateEndpointOverrides(environment: environment)

        let baseURL = ClinePassSettingsReader.apiURL(environment: environment)

        // The three reads are independent: each uses the literal `me` path
        // segment, so none depends on data returned by another. Fire them
        // concurrently to collapse three serialized round trips into one
        // (matching the Groq fetcher's parallel-query pattern). The task group
        // propagates any failure from the required user/plan tasks; the
        // best-effort limits task contains its own failure so a missing
        // usage-limits endpoint doesn't abort the group.
        var fetchedUser: ClinePassUserDTO?
        var fetchedPlan: ClinePassPlanDTO?
        var fetchedLimits: ClinePassUsageLimitsDTO?
        try await withThrowingTaskGroup(of: FetchPart.self) { group in
            group.addTask { try await .user(self.fetchUser(apiKey: apiKey, baseURL: baseURL, transport: transport)) }
            group.addTask { try await .plan(self.fetchPlan(apiKey: apiKey, baseURL: baseURL, transport: transport)) }
            group.addTask {
                do {
                    let result = try await self.fetchUsageLimits(apiKey: apiKey, baseURL: baseURL, transport: transport)
                    return .limits(result)
                } catch {
                    Self.log.error(
                        "ClinePass /plan/usage-limits unavailable, showing plan + email only: "
                            + error.localizedDescription)
                    return .limits(nil)
                }
            }
            for try await part in group {
                switch part {
                case let .user(value): fetchedUser = value
                case let .plan(value): fetchedPlan = value
                case let .limits(value): fetchedLimits = value
                }
            }
        }

        guard let user = fetchedUser, let plan = fetchedPlan else {
            throw ClinePassUsageError.apiError("ClinePass account read incomplete")
        }
        let email = user.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.makeSnapshot(
            planName: plan.plan?.displayName,
            accountEmail: (email?.isEmpty ?? true) ? nil : email,
            limits: fetchedLimits?.limits ?? [],
            now: now)
    }

    private static func makeSnapshot(
        planName: String?,
        accountEmail: String?,
        limits: [ClinePassUsageLimitsDTO.Limit],
        now: Date) -> ClinePassUsageSnapshot
    {
        func window(_ type: String) -> ClinePassWindow? {
            // Match the window type case-insensitively so a server-side casing
            // change does not silently drop the window.
            guard let limit = limits.first(where: { $0.type.caseInsensitiveCompare(type) == .orderedSame })
            else { return nil }
            // A present row with a null percent means "usage not reported", which
            // is distinct from "0% used / full quota" — omit the window rather
            // than showing a misleading 0%.
            guard let percentUsed = limit.percentUsed else { return nil }
            return ClinePassWindow(
                percentUsed: percentUsed,
                resetsAt: limit.resetsAt.flatMap(Self.parseTimestamp))
        }

        let snapshot = ClinePassUsageSnapshot(
            planName: planName?.trimmingCharacters(in: .whitespacesAndNewlines),
            accountEmail: accountEmail,
            fiveHour: window("five_hour"),
            weekly: window("weekly"),
            monthly: window("monthly"),
            updatedAt: now)

        // Surface the case where the endpoint returned rows but none matched a
        // known window type (e.g. a server-side rename) — otherwise it looks
        // identical to a genuinely empty response.
        if !limits.isEmpty, !snapshot.hasWindows {
            let types = limits.map(\.type).joined(separator: ",")
            Self.log.error("ClinePass usage-limits returned unrecognized window types: \(types)")
        }
        return snapshot
    }

    /// Builds a snapshot from `(type, percentUsed, resetsAt)` rows. Exposed
    /// (public) so tests and callers can construct snapshots without a live
    /// transport. `type` is one of `five_hour` / `weekly` / `monthly`; a nil
    /// `percentUsed` models a row whose usage the server did not report.
    public static func makeSnapshot(
        planName: String?,
        accountEmail: String?,
        limits: [(type: String, percentUsed: Double?, resetsAt: String?)],
        now: Date) -> ClinePassUsageSnapshot
    {
        self.makeSnapshot(
            planName: planName,
            accountEmail: accountEmail,
            limits: limits.map { ClinePassUsageLimitsDTO.Limit(
                type: $0.type,
                percentUsed: $0.percentUsed,
                resetsAt: $0.resetsAt) },
            now: now)
    }

    private static func fetchUser(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport) async throws -> ClinePassUserDTO
    {
        let url = try self.endpoint(baseURL: baseURL, encodedSuffix: "/api/v1/users/me", endpoint: "users/me")
        let data = try await self.get(apiKey: apiKey, url: url, endpoint: "users/me", transport: transport)
        return try self.decodeEnvelope(ClinePassUserDTO.self, from: data, endpoint: "users/me")
    }

    private static func fetchPlan(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport) async throws -> ClinePassPlanDTO
    {
        // Note: only the literal `me` works here; `/users/{id}/plan` returns 404.
        let url = try self.endpoint(baseURL: baseURL, encodedSuffix: "/api/v1/users/me/plan", endpoint: "plan")
        let data = try await self.get(apiKey: apiKey, url: url, endpoint: "plan", transport: transport)
        return try self.decodeEnvelope(ClinePassPlanDTO.self, from: data, endpoint: "plan")
    }

    private static func fetchUsageLimits(
        apiKey: String,
        baseURL: URL,
        transport: any ProviderHTTPTransport) async throws -> ClinePassUsageLimitsDTO
    {
        let url = try self.endpoint(
            baseURL: baseURL,
            encodedSuffix: "/api/v1/users/me/plan/usage-limits",
            endpoint: "usage-limits")
        let data = try await self.get(apiKey: apiKey, url: url, endpoint: "usage-limits", transport: transport)
        return try self.decodeEnvelope(ClinePassUsageLimitsDTO.self, from: data, endpoint: "usage-limits")
    }

    /// Parses an ISO8601 timestamp with variable-precision fractional seconds.
    /// Cline returns fractional-second precision; the two-formatter approach
    /// handles both fractional and whole-second timestamps without truncating
    /// timezone offsets (`Z`, `+HH:mm`, or `+HHmm`). Fresh formatters are
    /// created per call because `ISO8601DateFormatter` is not `Sendable`.
    static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// Appends an already-percent-encoded, `/api/v1`-versioned path suffix to
    /// `baseURL`, preserving any host-level base path prefix without re-encoding
    /// it. The `/api/v1` version segment is normalized out of the base first, so
    /// both `https://api.cline.bot` and Cline's documented versioned root
    /// `https://api.cline.bot/api/v1` resolve to the same endpoint instead of
    /// producing a doubled `/api/v1/api/v1/...` path.
    private static func endpoint(baseURL: URL, encodedSuffix: String, endpoint: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClinePassUsageError.apiError("Invalid ClinePass base URL for /\(endpoint)")
        }
        components.percentEncodedPath = Self.normalizedBasePath(components.percentEncodedPath) + encodedSuffix
        guard let url = components.url else {
            throw ClinePassUsageError.apiError("Invalid ClinePass URL for /\(endpoint)")
        }
        return url
    }

    /// Reduces a base URL's path to the host-level prefix that precedes the
    /// `/api/v1` version segment: strips a trailing slash, then a trailing
    /// `/api/v1` (case-insensitively). `""` and `"/api/v1"` both become `""`;
    /// `"/gateway/api/v1"` becomes `"/gateway"`; `"/gateway"` is left as-is.
    static func normalizedBasePath(_ rawPath: String) -> String {
        var path = rawPath
        if path.hasSuffix("/") { path.removeLast() }
        let versionSuffix = "/api/v1"
        if path.count >= versionSuffix.count,
           path.suffix(versionSuffix.count).lowercased() == versionSuffix
        {
            path.removeLast(versionSuffix.count)
        }
        return path
    }

    private static func get(
        apiKey: String,
        url: URL,
        endpoint: String,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.requestTimeoutSeconds

        let response = try await transport.response(for: request)
        guard response.statusCode == 200 else {
            let summary = LogRedactor.redact(Self.sanitizedResponseBodySummary(response.data))
            Self.log.error("ClinePass /\(endpoint) returned \(response.statusCode): \(summary)")
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ClinePassUsageError.invalidCredentials
            }
            throw ClinePassUsageError.apiError("HTTP \(response.statusCode)")
        }
        try self.validateSameOrigin(response: response, request: request, endpoint: endpoint)
        return response.data
    }

    private static func decodeEnvelope<T: Decodable>(
        _: T.Type,
        from data: Data,
        endpoint: String) throws -> T
    {
        do {
            let envelope = try JSONDecoder().decode(ClinePassEnvelope<T>.self, from: data)
            if envelope.success == false {
                throw ClinePassUsageError.apiError(envelope.error ?? "ClinePass /\(endpoint) request failed")
            }
            guard let payload = envelope.data else {
                throw ClinePassUsageError.parseFailed("Missing ClinePass /\(endpoint) data")
            }
            return payload
        } catch let error as ClinePassUsageError {
            throw error
        } catch let error as DecodingError {
            Self.log.error("ClinePass /\(endpoint) decode error: \(error.localizedDescription)")
            throw ClinePassUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func validateSameOrigin(
        response: ProviderHTTPResponse,
        request: URLRequest,
        endpoint: String) throws
    {
        guard let requestURL = request.url,
              let responseURL = response.response.url,
              let requestHost = requestURL.host?.lowercased(),
              let responseHost = responseURL.host?.lowercased(),
              requestURL.scheme?.lowercased() == responseURL.scheme?.lowercased(),
              requestHost == responseHost,
              self.effectivePort(for: requestURL) == self.effectivePort(for: responseURL)
        else {
            throw ClinePassUsageError.apiError("ClinePass /\(endpoint) redirected to a different origin")
        }
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "https":
            return 443
        case "http":
            return 80
        default:
            return nil
        }
    }

    private static func sanitizedResponseBodySummary(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty body" }
        guard let rawBody = String(bytes: data, encoding: .utf8) else {
            return "non-text body (\(data.count) bytes)"
        }

        let body = Self.redactSensitiveBodyContent(rawBody)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else { return "non-text body (\(data.count) bytes)" }
        guard body.count > Self.maxErrorBodyLength else { return body }

        let index = body.index(body.startIndex, offsetBy: Self.maxErrorBodyLength)
        return "\(body[..<index])… [truncated]"
    }

    private static func redactSensitiveBodyContent(_ text: String) -> String {
        let replacements: [(String, String)] = [
            (#"(?i)(bearer\s+)[A-Za-z0-9._\-]+"#, "$1[REDACTED]"),
            (
                #"(?i)(\"(?:api_?key|authorization|token|access_token|refresh_token)\"\s*:\s*\")([^\"]+)(\")"#,
                "$1[REDACTED]$3"),
            (
                #"(?i)((?:api_?key|authorization|token|access_token|refresh_token)\s*[=:]\s*)([^,\s]+)"#,
                "$1[REDACTED]"),
        ]

        return replacements.reduce(text) { partial, replacement in
            partial.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression)
        }
    }

    #if DEBUG
    static func _sanitizedResponseBodySummaryForTesting(_ body: String) -> String {
        self.sanitizedResponseBodySummary(Data(body.utf8))
    }
    #endif
}

/// Errors that can occur during ClinePass usage fetching.
public enum ClinePassUsageError: LocalizedError, Sendable, Equatable {
    case invalidCredentials
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Invalid ClinePass API credentials"
        case let .apiError(message):
            "ClinePass API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse ClinePass response: \(message)"
        }
    }
}
