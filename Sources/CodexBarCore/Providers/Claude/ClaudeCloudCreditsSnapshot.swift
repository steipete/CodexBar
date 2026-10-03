import Foundation

/// Promotional cloud-session credit, distinct from prepaid Extra usage and recurring rate limits.
/// The usage API reports these amounts in dollars, not minor currency units.
public struct ClaudeCloudCreditsSnapshot: Decodable, Equatable, Sendable {
    public static let detailTitle = "Cloud credits"
    public static let detailRowID = "claude-cloud-credits"
    private static let expiredValue = "Expired"
    private static let unavailableValue = "Unavailable"

    /// State recovered from the published detail row, so cached snapshots present like live ones.
    public enum DetailStatus: Equatable, Sendable {
        case available(remainingDollars: Double)
        case expired
        case unavailable
    }

    public let limitDollars: Double
    public let usedDollars: Double
    public let remainingDollars: Double
    public let expiresAt: Date?
    public let isLocked: Bool

    private enum CodingKeys: String, CodingKey {
        case limitDollars = "limit_dollars"
        case usedDollars = "used_dollars"
        case remainingDollars = "remaining_dollars"
        case expiresAt = "resets_at"
        case lockedReason = "locked_reason"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let limit = try container.decode(Double.self, forKey: .limitDollars)
        let used = try container.decodeIfPresent(Double.self, forKey: .usedDollars)
        let remaining = try container.decodeIfPresent(Double.self, forKey: .remainingDollars)
        guard limit.isFinite, limit > 0,
              used.map({ $0.isFinite && $0 >= 0 && $0 <= limit }) ?? true,
              remaining.map({ $0.isFinite && $0 >= 0 && $0 <= limit }) ?? true,
              let resolvedRemaining = remaining ?? used.map({ limit - $0 })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .limitDollars,
                in: container,
                debugDescription: "Cloud credits require a positive allowance and a valid dollar balance")
        }
        self.limitDollars = limit
        self.remainingDollars = resolvedRemaining
        // Prefer the reported remaining amount so the balance and progress always agree.
        self.usedDollars = limit - resolvedRemaining
        if let rawExpiry = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
            guard let expiry = ISO8601DateParser.parse(rawExpiry) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expiresAt, in: container, debugDescription: "Invalid cloud-credit expiration")
            }
            self.expiresAt = expiry
        } else {
            self.expiresAt = nil
        }
        let reason = try container.decodeIfPresent(String.self, forKey: .lockedReason)
        self.isLocked = reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// Web JSON and OAuth decoding share exactly the same validation and unit handling.
    static func parse(_ value: Any?) -> Self? {
        guard let object = value as? [String: Any],
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func detailSections(now: Date) -> [ProviderDetailSection] {
        let expired = self.expiresAt.map { $0 <= now } ?? false
        let value: String
        let progress: ProviderDetailSection.Row.Progress?
        if expired {
            value = Self.expiredValue
            progress = nil
        } else if self.isLocked {
            value = Self.unavailableValue
            progress = nil
        } else {
            let remaining = UsageFormatter.currencyString(self.remainingDollars, currencyCode: "USD")
            let limit = UsageFormatter.currencyString(self.limitDollars, currencyCode: "USD")
            value = "\(remaining) of \(limit) remaining"
            progress = .makeProgress(used: self.usedDollars, total: self.limitDollars)
        }
        // Absolute UTC timestamps remain meaningful in CLI output and persisted detail rows.
        let expiry = self.expiresAt.map { "\(expired ? "Expired" : "Expires") \($0.ISO8601Format())" }
        return [.makeSection(title: Self.detailTitle, rows: [
            .makeRow(
                id: Self.detailRowID,
                label: Self.detailTitle,
                value: value,
                secondaryValue: expiry,
                progress: progress,
                usageValue: expired || self.isLocked ? nil : self.remainingDollars),
        ])]
    }

    /// Reads back the row written by `detailSections(now:)`. A balance observed before its expiry is
    /// reported as expired once `now` passes the timestamp stored in the row.
    public static func detailStatus(in sections: [ProviderDetailSection], now: Date) -> DetailStatus? {
        guard let row = sections.lazy
            .filter({ $0.title == Self.detailTitle })
            .flatMap(\.rows)
            .first(where: { $0.id == Self.detailRowID })
        else { return nil }
        if row.value == Self.expiredValue { return .expired }
        let storedExpiry = row.secondaryValue?.split(separator: " ").last.map(String.init)
        if let expiry = ISO8601DateParser.parse(storedExpiry), expiry <= now {
            return .expired
        }
        guard let remaining = row.usageValue else { return .unavailable }
        return .available(remainingDollars: remaining)
    }
}
