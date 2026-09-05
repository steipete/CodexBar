import Foundation

public struct MuseUsageSnapshot: Sendable {
    public let summary: MuseLocalSessionSummary?
    public let updatedAt: Date

    public init(summary: MuseLocalSessionSummary?, updatedAt: Date = Date()) {
        self.summary = summary
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let costUsage = summary?.toCostUsageTokenSnapshot(
            historyDays: MuseLocalSessionScanner.defaultLookbackDays)
        let identity = ProviderIdentitySnapshot(
            providerID: .muse,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Muse")
        // Token-history only: no quota windows, no cost, no pace.
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            costUsage: costUsage,
            updatedAt: summary?.scannedAt ?? self.updatedAt,
            identity: costUsage != nil || summary?.requestCount ?? 0 > 0 ? identity : nil)
    }
}
