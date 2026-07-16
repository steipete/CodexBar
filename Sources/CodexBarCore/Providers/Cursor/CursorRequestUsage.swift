import Foundation

/// Request usage snapshot for legacy Cursor plans (request-based instead of token-based).
public struct CursorRequestUsage: Codable, Sendable {
    /// Requests used this billing cycle
    public let used: Int
    /// Request limit (e.g., 500 for legacy enterprise plans)
    public let limit: Int

    public init(used: Int, limit: Int) {
        self.used = used
        self.limit = limit
    }

    public var usedPercent: Double {
        guard self.limit > 0 else { return 0 }
        return (Double(self.used) / Double(self.limit)) * 100
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }
}

/// Aggregated Cursor Cloud Agent spend for the current billing cycle.
///
/// Cloud Agents draw from the same included/API/on-demand pools as local usage. This value is
/// spend *attribution* (share of cycle chargeable spend), not a separate quota.
public struct CursorCloudAgentUsage: Codable, Sendable, Equatable {
    public static let windowID = "cursor-cloud"
    public static let windowTitle = "Cloud"

    /// Cloud agent spend in USD for the billing cycle.
    public let usedUSD: Double
    /// Total chargeable spend in USD for the same cycle (local + cloud).
    public let totalSpendUSD: Double
    /// Number of chargeable cloud-agent events included in `usedUSD`.
    public let eventCount: Int

    public init(usedUSD: Double, totalSpendUSD: Double, eventCount: Int) {
        self.usedUSD = usedUSD
        self.totalSpendUSD = totalSpendUSD
        self.eventCount = eventCount
    }

    /// Share of cycle spend attributed to cloud agents (0-100).
    public var usedPercent: Double {
        guard self.totalSpendUSD > 0 else { return 0 }
        return max(0, min(100, (self.usedUSD / self.totalSpendUSD) * 100))
    }
}
