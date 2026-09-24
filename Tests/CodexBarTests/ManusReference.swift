import Foundation
@testable import CodexBarCore

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
        guard container.allKeys.contains(where: { $0 != .nextRefreshTime && $0 != .refreshInterval }) else {
            throw ManusAPIError.parseFailed("response missing expected credits fields")
        }
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

enum ManusReferenceParser {
    static func parseResponse(_ data: Data) throws -> ManusCreditsResponse {
        try JSONDecoder().decode(ManusCreditsEnvelope.self, from: data).credits
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
    let credits: ManusCreditsResponse

    private enum CodingKeys: String, CodingKey {
        case data, result, response, availableCredits
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.credits = try container.decodeIfPresent(ManusCreditsResponse.self, forKey: .data) ??
            container.decodeIfPresent(ManusCreditsResponse.self, forKey: .result) ??
            container.decodeIfPresent(ManusCreditsResponse.self, forKey: .response) ??
            container.decodeIfPresent(ManusCreditsResponse.self, forKey: .availableCredits) ??
            ManusCreditsResponse(from: decoder)
    }
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
