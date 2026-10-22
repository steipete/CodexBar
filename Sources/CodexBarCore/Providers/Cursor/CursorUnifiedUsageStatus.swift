import Foundation

/// Additional spend on unified Cursor/Grok accounts. The legacy summary can report a false zero.
public struct CursorUnifiedUsageStatus: Decodable, Sendable {
    static let endpointPath = "/api/dashboard/v2/usage-status"

    public struct MonthlyUsage: Decodable, Sendable {
        public let usedCents: Double
        public let limitCents: Double
        public let periodStart: String
        public let resetsAt: String
    }

    public let availability: String
    public let monthlyUsage: MonthlyUsage?

    func currentMonthlyUsage(at now: Date) -> MonthlyUsage? {
        guard self.availability == "available",
              let usage = self.monthlyUsage,
              usage.usedCents.isFinite, usage.usedCents >= 0,
              usage.limitCents.isFinite, usage.limitCents >= 0,
              let start = ISO8601DateParser.parse(usage.periodStart),
              let reset = ISO8601DateParser.parse(usage.resetsAt),
              start <= now, now < reset
        else { return nil }
        return usage
    }
}

extension CursorUsageSummary {
    var usesUnifiedPersonalBilling: Bool {
        self.membershipType?.lowercased().hasPrefix("unified_") == true
            && self.limitType?.lowercased() == "user"
    }
}
