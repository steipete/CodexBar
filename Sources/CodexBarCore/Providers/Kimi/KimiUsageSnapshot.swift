import Foundation

public struct KimiUsageSnapshot: Sendable, Equatable {
    public let summary: KimiUsageRow?
    public let limits: [KimiUsageRow]
    public let updatedAt: Date

    public init(summary: KimiUsageRow?, limits: [KimiUsageRow], updatedAt: Date) {
        self.summary = summary
        self.limits = limits
        self.updatedAt = updatedAt
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func rateWindow(from row: KimiUsageRow, prefixLabel: Bool) -> RateWindow {
        let clampedLimit = max(row.limit, 0)
        let clampedUsed = max(0, min(row.used, clampedLimit == 0 ? row.used : clampedLimit))
        let usedPercent = clampedLimit > 0 ? (Double(clampedUsed) / Double(clampedLimit) * 100) : 0
        let descriptionPrefix = prefixLabel ? "\(row.label): " : ""

        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: row.windowMinutes,
            resetsAt: Self.parseDate(row.resetAt),
            resetDescription: "\(descriptionPrefix)\(clampedUsed)/\(clampedLimit)")
    }
}

extension KimiUsageSnapshot {
    public func toUsageSnapshot() -> UsageSnapshot {
        let identity = ProviderIdentitySnapshot(
            providerID: .kimi,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)

        let summaryWindow = self.summary.map { Self.rateWindow(from: $0, prefixLabel: false) }
        let secondaryWindow = self.limits.indices.contains(0)
            ? Self.rateWindow(from: self.limits[0], prefixLabel: true)
            : nil
        let tertiaryWindow = self.limits.indices.contains(1)
            ? Self.rateWindow(from: self.limits[1], prefixLabel: true)
            : nil

        return UsageSnapshot(
            primary: summaryWindow,
            secondary: secondaryWindow,
            tertiary: tertiaryWindow,
            providerCost: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}
