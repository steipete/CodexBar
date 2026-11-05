import Foundation

/// A deliberately small interchange format: no identity, URLs, headers, or executable content.
struct QuotaFeedSnapshot: Decodable, Sendable {
    let version: Int
    let observedAt: Date
    let used: Double
    let limit: Double
    let currency: String?
    let resetsAt: Date?

    static let maximumBytes = 64 * 1024
    static let maximumAge: TimeInterval = 15 * 60

    static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= self.maximumBytes else { throw QuotaFeedError.invalidData }
        let allowed: Set = ["version", "observedAt", "used", "limit", "currency", "resetsAt"]
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: allowed) else { throw QuotaFeedError.invalidData }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(Self.self, from: data),
              value.version == 1,
              value.used.isFinite, value.used >= 0,
              value.limit.isFinite, value.limit >= 0,
              value.limit == 0 || (value.used / value.limit * 100).isFinite,
              value.currency.map({ code in
                  code.utf8.count == 3 && code.utf8.allSatisfy { (65...90).contains($0) }
              }) ?? true
        else { throw QuotaFeedError.invalidData }
        guard value.observedAt.timeIntervalSince(now) <= 60,
              now.timeIntervalSince(value.observedAt) <= self.maximumAge,
              value.resetsAt.map({ $0 > now }) ?? true else { throw QuotaFeedError.staleData }
        return value
    }

    func usageSnapshot() throws -> UsageSnapshot {
        let remaining = self.limit - self.used
        let format: (Double) -> String = { value in
            let amount = String(format: abs(value) >= 1e12 ? "%.6g" : "%.2f", value)
            return self.currency.map { amount + " " + $0 } ?? amount
        }
        let details = try ProviderDetailSection(title: "Quota", rows: [
            .init(label: "Used", value: format(self.used)),
            .init(label: "Limit", value: format(self.limit)),
            .init(label: "Remaining", value: format(remaining)),
        ])
        return UsageSnapshot(
            primary: self.limit > 0 ? RateWindow(
                usedPercent: self.used / self.limit * 100,
                windowMinutes: nil,
                resetsAt: self.resetsAt,
                resetDescription: nil) : nil,
            secondary: nil,
            providerCost: self.currency.map {
                ProviderCostSnapshot(
                    used: self.used,
                    limit: self.limit,
                    currencyCode: $0,
                    resetsAt: self.resetsAt,
                    updatedAt: self.observedAt)
            },
            details: [details],
            updatedAt: self.observedAt)
    }
}

public enum QuotaFeedError: LocalizedError, Sendable, Equatable {
    case missingPath
    case unreadableFile
    case invalidData
    case staleData

    public var errorDescription: String? {
        switch self {
        case .missingPath:
            "Choose an absolute path to a local quota JSON file in Quota Feed settings."
        case .unreadableFile:
            "Cannot read the quota feed. Choose a readable regular file, not a symlink or pipe."
        case .invalidData:
            "Invalid quota feed. Use the documented version 1 schema, with a maximum size of 64 KiB."
        case .staleData:
            "Quota feed is stale or its clock is incorrect. Refresh it within 15 minutes and after each reset."
        }
    }
}
