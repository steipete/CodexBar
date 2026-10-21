import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum TraeCNSettingsError: LocalizedError, Sendable, Equatable {
    case missingCookie(details: String? = nil)
    case invalidCookie
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case let .missingCookie(details):
            [
                "No Trae CN session found. Paste a Cookie header from trae.cn in Settings first.",
                details,
            ]
                .compactMap(\.self)
                .joined(separator: " ")
        case .invalidCookie:
            "Trae CN requires a valid Cookie header copied from trae.cn."
        case let .invalidEndpointOverride(key):
            "Trae CN endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}

public enum TraeCNUsageError: LocalizedError, Sendable {
    case invalidCredentials
    case loginRequired
    case parseFailed(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Trae CN session was rejected. Paste a fresh Cookie header."
        case .loginRequired:
            "Trae CN login required. Log in at trae.cn and paste a fresh Cookie header."
        case let .parseFailed(message):
            "Could not parse Trae CN credits: \(message)"
        case let .networkError(message):
            "Trae CN request failed: \(message)"
        }
    }
}

public enum TraeCNSettingsReader {
    public static let apiURLKey = "TRAECN_API_URL"

    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = self.cleaned(environment[self.apiURLKey]),
           let url = ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: override)
        {
            return url
        }
        return URL(string: "https://api.trae.cn")!
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let override = self.cleaned(environment[self.apiURLKey]),
              ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: override) == nil else { return }
        throw TraeCNSettingsError.invalidEndpointOverride(self.apiURLKey)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

public enum TraeCNUsageFetcher {
    private static let requestTimeout: TimeInterval = 15

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    public static func fetchUsage(
        cookieHeader: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> TraeCNUsageSnapshot
    {
        guard let normalizedCookie = TraeCNCookieHeader.normalizedHeader(from: cookieHeader) else {
            throw TraeCNSettingsError.invalidCookie
        }
        try TraeCNSettingsReader.validateEndpointOverrides(environment: environment)
        let baseURL = TraeCNSettingsReader.apiURL(environment: environment)

        // Session cookies are long-lived, but the entitlement API requires a short-lived
        // (~8h) Cloud-IDE-JWT exchanged via GetUserToken. Cache it until expiry.
        let token = try await self.userToken(
            baseURL: baseURL,
            cookie: normalizedCookie,
            transport: transport,
            forceRefresh: false)
        do {
            let data = try await self.fetchEntitlement(
                baseURL: baseURL,
                cookie: normalizedCookie,
                token: token,
                transport: transport)
            return try self.parseEntitlementSnapshot(from: data, now: now)
        } catch TraeCNUsageError.loginRequired {
            // The cached JWT may have expired early; exchange a fresh one and retry once.
            await TraeCNTokenCache.shared.clear(cookie: normalizedCookie)
            let freshToken = try await self.userToken(
                baseURL: baseURL,
                cookie: normalizedCookie,
                transport: transport,
                forceRefresh: true)
            let data = try await self.fetchEntitlement(
                baseURL: baseURL,
                cookie: normalizedCookie,
                token: freshToken,
                transport: transport)
            return try self.parseEntitlementSnapshot(from: data, now: now)
        }
    }

    private static func userToken(
        baseURL: URL,
        cookie: String,
        transport: any ProviderHTTPTransport,
        forceRefresh: Bool) async throws -> String
    {
        if !forceRefresh, let cached = await TraeCNTokenCache.shared.token(forCookie: cookie) {
            return cached
        }

        let url = baseURL.appendingPathComponent("cloudide/api/v3/common/GetUserToken")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.trae.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://www.trae.cn/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data()

        let response = try await transport.response(for: request)
        switch response.statusCode {
        case 200:
            break
        case 300..<400, 401:
            throw TraeCNUsageError.loginRequired
        case 403:
            throw TraeCNUsageError.invalidCredentials
        default:
            throw TraeCNUsageError.networkError("GetUserToken HTTP \(response.statusCode)")
        }

        let decoded: UserTokenResponse
        do {
            decoded = try JSONDecoder().decode(UserTokenResponse.self, from: response.data)
        } catch {
            throw TraeCNUsageError.parseFailed("Unexpected GetUserToken response shape")
        }
        guard let token = decoded.result?.token, !token.isEmpty else {
            throw TraeCNUsageError.parseFailed("Missing token in GetUserToken response")
        }

        let expiresAt = Self.jwtExpiryDate(token) ?? Date().addingTimeInterval(8 * 3600)
        await TraeCNTokenCache.shared.store(cookie: cookie, token: token, expiresAt: expiresAt)
        return token
    }

    static func jwtExpiryDate(_ jwt: String) -> Date? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? TimeInterval
        else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    private static func fetchEntitlement(
        baseURL: URL,
        cookie: String,
        token: String,
        transport: any ProviderHTTPTransport) async throws -> Data
    {
        let url = baseURL.appendingPathComponent("trae/api/v2/pay/user_current_entitlement_list")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Cloud-IDE-JWT \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.trae.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://www.trae.cn/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(#"{"require_usage":true,"full_data":true}"#.utf8)

        let response = try await transport.response(for: request)

        switch response.statusCode {
        case 200:
            break
        // Expired sessions can redirect API requests to the login flow.
        case 300..<400:
            throw TraeCNUsageError.loginRequired
        case 401:
            throw TraeCNUsageError.loginRequired
        case 403:
            throw TraeCNUsageError.invalidCredentials
        default:
            throw TraeCNUsageError.networkError("HTTP \(response.statusCode)")
        }

        return response.data
    }

    /// The v2 entitlement endpoint returns the payload directly (no code/message wrapper).
    /// `usage_summary` is the authoritative aggregate across all credit packs.
    static func parseEntitlementSnapshot(from data: Data, now: Date = Date()) throws -> TraeCNUsageSnapshot {
        let decoder = JSONDecoder()
        let response: EntitlementResponse
        do {
            response = try decoder.decode(EntitlementResponse.self, from: data)
        } catch {
            throw TraeCNUsageError.parseFailed("Unexpected response shape")
        }

        guard let summary = response.usageSummary,
              let limit = summary.totalAmount, limit > 0
        else {
            throw TraeCNUsageError.parseFailed("Missing usage summary")
        }
        let used = summary.consumedAmount ?? 0

        // The subscription pack (group_type 0) drives the reset countdown: credits refresh
        // when the current period ends (expire_time); next_billing_time is the fallback.
        let subscription = response.userEntitlementPackList?.first { $0.groupType == 0 }
        let periodEnd: Date? = {
            if let expire = subscription?.expireTime, expire > 0 {
                return Date(timeIntervalSince1970: expire)
            }
            if let nextBilling = subscription?.nextBillingTime, nextBilling > 0 {
                return Date(timeIntervalSince1970: nextBilling)
            }
            return nil
        }()

        return TraeCNUsageSnapshot(
            creditsUsed: used,
            creditsLimit: limit,
            creditsRemaining: limit - used,
            planCode: subscription?.displayDesc,
            planPeriodEnd: periodEnd,
            updatedAt: now)
    }

    private struct UserTokenResponse: Decodable {
        let result: ResultPayload?

        enum CodingKeys: String, CodingKey {
            case result = "Result"
        }
    }

    private struct ResultPayload: Decodable {
        let token: String?

        enum CodingKeys: String, CodingKey {
            case token = "Token"
        }
    }

    private struct EntitlementResponse: Decodable {
        let usageSummary: UsageSummary?
        let userEntitlementPackList: [EntitlementPack]?

        enum CodingKeys: String, CodingKey {
            case usageSummary = "usage_summary"
            case userEntitlementPackList = "user_entitlement_pack_list"
        }
    }

    private struct UsageSummary: Decodable {
        let consumedAmount: Double?
        let consumptionRatio: Double?
        let totalAmount: Double?

        enum CodingKeys: String, CodingKey {
            case consumedAmount = "consumed_amount"
            case consumptionRatio = "consumption_ratio"
            case totalAmount = "total_amount"
        }
    }

    private struct EntitlementPack: Decodable {
        let displayDesc: String?
        let groupType: Int?
        let expireTime: TimeInterval?
        let nextBillingTime: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case displayDesc = "display_desc"
            case groupType = "group_type"
            case expireTime = "expire_time"
            case nextBillingTime = "next_billing_time"
        }
    }
}

/// In-process cache for the exchanged Cloud-IDE-JWT, keyed by the full cookie header.
/// Tokens outlive a single refresh cycle (~8h), so this avoids a GetUserToken round-trip
/// on every menu bar refresh.
actor TraeCNTokenCache {
    static let shared = TraeCNTokenCache()

    private var entry: (cookie: String, token: String, expiresAt: Date)?

    func token(forCookie cookie: String, now: Date = Date()) -> String? {
        guard let entry,
              entry.cookie == cookie,
              entry.expiresAt > now.addingTimeInterval(60)
        else {
            return nil
        }
        return entry.token
    }

    func store(cookie: String, token: String, expiresAt: Date) {
        self.entry = (cookie, token, expiresAt)
    }

    func clear(cookie: String) {
        if self.entry?.cookie == cookie {
            self.entry = nil
        }
    }
}
