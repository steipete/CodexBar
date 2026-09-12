import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CoreFoundation)
import CoreFoundation
#endif

public enum VeniceWebUsageFetcher {
    public static let sessionURL = URL(string: "https://outerface.venice.ai/api/user/session")!
    public static let defaultTimeout: TimeInterval = 15
    private static let log = CodexBarLog.logger(LogCategories.provider(.venice, scope: "usage"))
    private static let expirationSkew: TimeInterval = 60
    private static let saneUnixSeconds = 1_000_000_000.0...4_000_000_000.0
    private static let anonymousUserTypes: Set<String> = [
        "anonymous",
        "anon",
        "guest",
        "unauthenticated",
        "logged_out",
    ]

    public static func fetchUsage(
        cookieHeader: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = Self.defaultTimeout,
        now: Date = Date()) async throws -> UsageSnapshot
    {
        let header = try Self.requireSessionCookieHeader(cookieHeader)
        var request = URLRequest(url: self.sessionURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(header, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            throw VeniceUsageError.networkError(error.localizedDescription)
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            throw VeniceUsageError.invalidCredentials
        }
        guard (200..<300).contains(response.statusCode) else {
            Self.log.error("Venice session → \(response.statusCode)")
            throw VeniceUsageError.apiError(response.statusCode)
        }
        return try self.snapshot(fromSessionData: response.data, now: now)
    }

    static func snapshot(fromSessionData data: Data, now: Date = Date()) throws -> UsageSnapshot {
        let object = try self.sessionObject(from: data)
        guard let token = self.string(object["token"]), !token.isEmpty else {
            throw VeniceUsageError.parseFailed("session response missing token")
        }
        guard let claims = UsageFetcher.parseJWT(token) else {
            throw VeniceUsageError.parseFailed("session token payload is not a JWT")
        }
        return try self.snapshot(fromClaims: claims, now: now)
    }

    static func snapshot(fromClaims claims: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        try self.validateExpiration(in: claims, now: now)

        let userType = self.string(claims["userType"])
        if let userType, self.anonymousUserTypes.contains(userType.lowercased()) {
            throw VeniceUsageError.anonymousSession
        }

        guard let usage = claims["bundledCreditsUsage"] as? [String: Any] else {
            throw VeniceUsageError.missingQuota
        }

        guard let usedThisCycle = self.finiteNonNegative(usage["usedThisCycle"]),
              let monthlyRefillCredits = self.finiteNonNegative(usage["monthlyRefillCredits"]),
              monthlyRefillCredits > 0
        else {
            throw VeniceUsageError.missingQuota
        }

        let availableCredits = self.finiteNonNegative(usage["availableCredits"])
            ?? self.finiteNonNegative(claims["bundledCredits"])
        let veniceCredits = self.finiteNonNegative(claims["veniceCredits"])
        let tierCap = self.finiteNonNegative(usage["tierCap"])
        let nextRefillAt = self.date(fromEpoch: self.finiteNonNegative(usage["nextRefillAt"]))

        let usedPercent = UsagePercent(used: usedThisCycle, limit: monthlyRefillCredits).raw
        guard usedPercent.isFinite else { throw VeniceUsageError.missingQuota }
        let resetDescription = nextRefillAt.map { UsageFormatter.resetDescription(from: $0, now: now) }
        let primary = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
            resetsAt: nextRefillAt,
            resetDescription: resetDescription)

        let details = Self.makeDetails(CreditDetails(
            usedThisCycle: usedThisCycle,
            monthlyRefillCredits: monthlyRefillCredits,
            availableCredits: availableCredits,
            veniceCredits: veniceCredits,
            tierCap: tierCap,
            userType: userType))

        let identity = ProviderIdentitySnapshot(
            providerID: .venice,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            details: details,
            subscriptionRenewsAt: nextRefillAt,
            updatedAt: now,
            identity: identity,
            dataConfidence: .exact)
    }

    private static func requireSessionCookieHeader(_ raw: String) throws -> String {
        guard let header = VeniceCookieHeader.header(from: raw) else {
            throw VeniceUsageError.missingCredentials
        }
        return header
    }

    private static func sessionObject(from data: Data) throws -> [String: Any] {
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw VeniceUsageError.parseFailed("session response is not JSON")
        }
        guard let object = decoded as? [String: Any] else {
            throw VeniceUsageError.parseFailed("session response is not an object")
        }
        return object
    }

    private struct CreditDetails {
        let usedThisCycle: Double
        let monthlyRefillCredits: Double
        let availableCredits: Double?
        let veniceCredits: Double?
        let tierCap: Double?
        let userType: String?
    }

    private static func makeDetails(_ details: CreditDetails) -> [ProviderDetailSection] {
        var rows: [ProviderDetailSection.Row] = [
            ProviderDetailSection.makeRow(label: "Used this cycle", value: self.formatCredits(details.usedThisCycle)),
            ProviderDetailSection.makeRow(
                label: "Monthly allowance",
                value: self.formatCredits(details.monthlyRefillCredits)),
        ]
        if let availableCredits = details.availableCredits {
            rows.append(ProviderDetailSection.makeRow(
                label: "Subscription remaining",
                value: self.formatCredits(availableCredits)))
        }
        if let tierCap = details.tierCap {
            rows.append(ProviderDetailSection.makeRow(label: "Bank cap", value: self.formatCredits(tierCap)))
        }
        if let veniceCredits = details.veniceCredits {
            rows.append(ProviderDetailSection.makeRow(label: "Total credits", value: self.formatCredits(veniceCredits)))
        }
        if let userType = details.userType, !userType.isEmpty {
            rows.append(ProviderDetailSection.makeRow(label: "Plan", value: userType))
        }
        return [ProviderDetailSection.makeSection(title: "Credits", rows: rows)]
    }

    private static func validateExpiration(in claims: [String: Any], now: Date) throws {
        guard let exp = self.finiteNonNegative(claims["exp"]), self.saneUnixSeconds.contains(exp) else {
            throw VeniceUsageError.expiredSession
        }
        let expiration = Date(timeIntervalSince1970: exp)
        guard expiration.timeIntervalSince(now) > -self.expirationSkew else {
            throw VeniceUsageError.expiredSession
        }
    }

    private static func date(fromEpoch value: Double?) -> Date? {
        guard let value else { return nil }
        let seconds = value / 1000
        guard self.saneUnixSeconds.contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func finiteNonNegative(_ value: Any?) -> Double? {
        guard let number = self.finiteNumber(value), number >= 0 else { return nil }
        return number
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            #if canImport(CoreFoundation)
            guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
            #endif
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let string = value as? String, let double = Double(string), double.isFinite {
            return double
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formatCredits(_ value: Double) -> String {
        // Pinned locale keeps detail rows deterministic across machines; grouping
        // keeps large credit balances readable.
        value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...2)))
    }
}
