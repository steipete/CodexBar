import Foundation

public struct QwenCloudUsageSnapshot: Sendable, OneConsoleTokenPlanSnapshot {
    public let planName: String?
    public let usedQuota: Double?
    public let totalQuota: Double?
    public let remainingQuota: Double?
    public let resetsAt: Date?
    public let fiveHourUsedPercent: Double?
    public let fiveHourTotalQuota: Double?
    public let fiveHourResetsAt: Date?
    public let weeklyUsedPercent: Double?
    public let weeklyTotalQuota: Double?
    public let weeklyResetsAt: Date?
    public let updatedAt: Date

    public init(
        planName: String?,
        usedQuota: Double?,
        totalQuota: Double?,
        remainingQuota: Double?,
        resetsAt: Date?,
        fiveHourUsedPercent: Double? = nil,
        fiveHourTotalQuota: Double? = nil,
        fiveHourResetsAt: Date? = nil,
        weeklyUsedPercent: Double? = nil,
        weeklyTotalQuota: Double? = nil,
        weeklyResetsAt: Date? = nil,
        updatedAt: Date)
    {
        self.planName = planName
        self.usedQuota = usedQuota
        self.totalQuota = totalQuota
        self.remainingQuota = remainingQuota
        self.resetsAt = resetsAt
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.fiveHourTotalQuota = fiveHourTotalQuota
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyTotalQuota = weeklyTotalQuota
        self.weeklyResetsAt = weeklyResetsAt
        self.updatedAt = updatedAt
    }
}

extension QwenCloudUsageSnapshot {
    init(alibabaSnapshot: AlibabaTokenPlanUsageSnapshot) {
        self.init(
            planName: alibabaSnapshot.planName,
            usedQuota: alibabaSnapshot.usedQuota,
            totalQuota: alibabaSnapshot.totalQuota,
            remainingQuota: alibabaSnapshot.remainingQuota,
            resetsAt: alibabaSnapshot.resetsAt,
            updatedAt: alibabaSnapshot.updatedAt)
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        self.usageSnapshot(for: .qwencloud)
    }
}
