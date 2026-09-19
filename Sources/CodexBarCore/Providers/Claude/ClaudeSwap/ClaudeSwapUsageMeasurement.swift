import Foundation

/// The shared window shape of live `usage` and display-only `lastGoodUsage`.
public struct ClaudeSwapUsageMeasurement: Equatable, Sendable {
    public let fiveHour: ClaudeSwapUsageWindow?
    public let sevenDay: ClaudeSwapUsageWindow?
    public let scoped: [ClaudeSwapScopedUsageWindow]
    public let spend: ClaudeSwapSpendWindow?

    public init(
        fiveHour: ClaudeSwapUsageWindow?,
        sevenDay: ClaudeSwapUsageWindow?,
        scoped: [ClaudeSwapScopedUsageWindow] = [],
        spend: ClaudeSwapSpendWindow? = nil)
    {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.scoped = scoped
        self.spend = spend
    }

    public var isEmpty: Bool {
        self.fiveHour == nil && self.sevenDay == nil && self.scoped.isEmpty && self.spend == nil
    }
}

public struct ClaudeSwapLastGoodUsage: Equatable, Sendable {
    public let measurement: ClaudeSwapUsageMeasurement
    public let fetchedAt: Date

    public init(measurement: ClaudeSwapUsageMeasurement, fetchedAt: Date) {
        self.measurement = measurement
        self.fetchedAt = fetchedAt
    }
}

public struct ClaudeSwapSpendWindow: Equatable, Sendable {
    public let used: Double
    public let limit: Double
    public let usedPercent: Double
    public let currencyCode: String
    public let resetsAt: Date?

    public init(used: Double, limit: Double, usedPercent: Double, currencyCode: String, resetsAt: Date?) {
        self.used = used
        self.limit = limit
        self.usedPercent = usedPercent
        self.currencyCode = currencyCode
        self.resetsAt = resetsAt
    }
}
