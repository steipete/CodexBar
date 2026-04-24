import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ManusCreditsResponse: Decodable, Sendable {
    public let totalCredits: Double
    public let freeCredits: Double
    public let periodicCredits: Double
    public let addonCredits: Double
    public let refreshCredits: Double
    public let maxRefreshCredits: Double
    public let proMonthlyCredits: Double
    public let eventCredits: Double
    public let nextRefreshTime: Date?
    public let refreshInterval: String?

    public init(
        totalCredits: Double,
        freeCredits: Double,
        periodicCredits: Double,
        addonCredits: Double,
        refreshCredits: Double,
        maxRefreshCredits: Double,
        proMonthlyCredits: Double,
        eventCredits: Double,
        nextRefreshTime: Date? = nil,
        refreshInterval: String? = nil)
    {
        self.totalCredits = totalCredits
        self.freeCredits = freeCredits
        self.periodicCredits = periodicCredits
        self.addonCredits = addonCredits
        self.refreshCredits = refreshCredits
        self.maxRefreshCredits = maxRefreshCredits
        self.proMonthlyCredits = proMonthlyCredits
        self.eventCredits = eventCredits
        self.nextRefreshTime = nextRefreshTime
        self.refreshInterval = refreshInterval
    }

    private enum CodingKeys: String, CodingKey {
        case totalCredits
        case freeCredits
        case periodicCredits
        case addonCredits
        case refreshCredits
        case maxRefreshCredits
        case proMonthlyCredits
        case eventCredits
        case nextRefreshTime
        case refreshInterval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.totalCredits = container.decodeLossyDoubleIfPresent(forKey: .totalCredits) ?? 0
        self.freeCredits = container.decodeLossyDoubleIfPresent(forKey: .freeCredits) ?? 0
        self.periodicCredits = container.decodeLossyDoubleIfPresent(forKey: .periodicCredits) ?? 0
        self.addonCredits = container.decodeLossyDoubleIfPresent(forKey: .addonCredits) ?? 0
        self.refreshCredits = container.decodeLossyDoubleIfPresent(forKey: .refreshCredits) ?? 0
        self.maxRefreshCredits = container.decodeLossyDoubleIfPresent(forKey: .maxRefreshCredits) ?? 0
        self.proMonthlyCredits = container.decodeLossyDoubleIfPresent(forKey: .proMonthlyCredits) ?? 0
        self.eventCredits = container.decodeLossyDoubleIfPresent(forKey: .eventCredits) ?? 0
        self.nextRefreshTime = container.decodeIfPresentFlexibleDate(forKey: .nextRefreshTime)
        self.refreshInterval = try? container.decodeIfPresent(String.self, forKey: .refreshInterval)
    }
}

public enum ManusUsageFetcher {
    private static let log = CodexBarLog.logger(LogCategories.manusAPI)
    private static let creditsURL =
        URL(string: "https://api.manus.im/user.v1.UserService/GetAvailableCredits")!
    @TaskLocal static var fetchCreditsOverride:
        (@Sendable (String, Date) async throws -> ManusCreditsResponse)?

    public static func fetchCredits(
        sessionToken: String,
        now: Date = Date()) async throws -> ManusCreditsResponse
    {
        if let override = self.fetchCreditsOverride {
            return try await override(sessionToken, now)
        }

        guard !sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManusAPIError.missingToken
        }

        var request = URLRequest(url: self.creditsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("https://manus.im", forHTTPHeaderField: "Origin")
        request.setValue("https://manus.im/", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
        request.setValue(
            userAgent,
            forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManusAPIError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            let truncated = body.count > 200 ? String(body.prefix(200)) + "…" : body
            Self.log.error("Manus API returned \(httpResponse.statusCode): \(truncated)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ManusAPIError.invalidToken
            }
            throw ManusAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try self.parseResponse(data)
        } catch let error as ManusAPIError {
            throw error
        } catch {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            Self.log.error("Manus parse failed: \(error) — response: \(preview)")
            throw ManusAPIError.parseFailed(error.localizedDescription)
        }
    }

    public static func parseResponse(_ data: Data) throws -> ManusCreditsResponse {
        let decoder = JSONDecoder()

        // Try envelope first — the direct decoder defaults missing fields to 0,
        // so it would "succeed" on wrapped payloads and silently return zero credits.
        if let envelope = try? decoder.decode(ManusCreditsEnvelope.self, from: data),
           let response = envelope.data ?? envelope.result ?? envelope.response ?? envelope.availableCredits
        {
            return response
        }

        let response = try decoder.decode(ManusCreditsResponse.self, from: data)
        // The custom decoder defaults every numeric field to 0, so an unrelated JSON
        // object (e.g. an error payload) would otherwise surface as a bogus zero-credit
        // snapshot. Require at least one known credits key in the raw payload.
        guard Self.payloadContainsCreditsField(data: data) else {
            throw ManusAPIError.parseFailed("response missing expected credits fields")
        }
        return response
    }

    private static let expectedCreditsKeys: Set<String> = [
        "totalCredits", "freeCredits", "periodicCredits", "addonCredits",
        "refreshCredits", "maxRefreshCredits", "proMonthlyCredits", "eventCredits",
    ]

    private static func payloadContainsCreditsField(data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return !Self.expectedCreditsKeys.isDisjoint(with: object.keys)
    }
}

extension ManusCreditsResponse {
    public func toUsageSnapshot(now: Date = Date()) -> UsageSnapshot {
        let primary: RateWindow? = if self.proMonthlyCredits > 0 {
            RateWindow(
                usedPercent: min(
                    100,
                    max(0, (self.proMonthlyCredits - self.periodicCredits) / self.proMonthlyCredits * 100)),
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: Self.monthlyDetail(totalCredits: self.totalCredits, freeCredits: self.freeCredits))
        } else {
            nil
        }

        let secondary: RateWindow? = if self.maxRefreshCredits > 0 {
            RateWindow(
                usedPercent: min(
                    100,
                    max(0, (self.maxRefreshCredits - self.refreshCredits) / self.maxRefreshCredits * 100)),
                windowMinutes: nil,
                resetsAt: self.nextRefreshTime,
                resetDescription: Self.refreshDetail(
                    refreshCredits: self.refreshCredits,
                    maxRefreshCredits: self.maxRefreshCredits,
                    refreshInterval: self.refreshInterval))
        } else {
            nil
        }

        let balance = Self.creditCountString(self.totalCredits)
        let identity = ProviderIdentitySnapshot(
            providerID: .manus,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Balance: \(balance) credits")

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: now,
            identity: identity)
    }

    private static func creditCountString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }

    private static func monthlyDetail(totalCredits: Double, freeCredits: Double) -> String? {
        let total = self.creditCountString(totalCredits)
        let free = self.creditCountString(freeCredits)
        return "Total \(total) • Free \(free)"
    }

    private static func refreshDetail(
        refreshCredits: Double,
        maxRefreshCredits: Double,
        refreshInterval: String?) -> String?
    {
        let refresh = self.creditCountString(refreshCredits)
        let maxRefresh = self.creditCountString(maxRefreshCredits)
        if let refreshInterval, !refreshInterval.isEmpty {
            return "\(refreshInterval.capitalized): \(refresh) / \(maxRefresh)"
        }
        return "\(refresh) / \(maxRefresh)"
    }
}

public enum ManusAPIError: LocalizedError, Equatable, Sendable {
    case missingToken
    case invalidCookie
    case invalidToken
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "No Manus session token provided."
        case .invalidCookie:
            "Manus session cookie is invalid."
        case .invalidToken:
            "Invalid Manus session token."
        case let .networkError(message):
            "Manus network error: \(message)"
        case let .apiError(message):
            "Manus API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse Manus response: \(message)"
        }
    }
}

private struct ManusCreditsEnvelope: Decodable {
    let data: ManusCreditsResponse?
    let result: ManusCreditsResponse?
    let response: ManusCreditsResponse?
    let availableCredits: ManusCreditsResponse?
}

extension KeyedDecodingContainer where K: CodingKey {
    fileprivate func decodeLossyDoubleIfPresent(forKey key: K) -> Double? {
        if let value = try? self.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let intValue = try? self.decodeIfPresent(Int.self, forKey: key) {
            return Double(intValue)
        }
        if let stringValue = try? self.decodeIfPresent(String.self, forKey: key) {
            return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    fileprivate func decodeIfPresentFlexibleDate(forKey key: K) -> Date? {
        if let value = try? self.decodeIfPresent(Date.self, forKey: key) {
            return value
        }
        guard let stringValue = try? self.decodeIfPresent(String.self, forKey: key),
              !stringValue.isEmpty
        else {
            return nil
        }
        return ISO8601DateFormatter().date(from: stringValue)
    }
}
