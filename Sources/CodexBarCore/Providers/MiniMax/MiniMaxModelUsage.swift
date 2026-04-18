import Foundation

/// One quota row from `coding_plan/remains` `model_remains[]` (Token Plan).
public struct MiniMaxModelUsage: Sendable, Equatable {
    public enum WindowKind: Sendable, Equatable {
        case fiveHour
        case daily
        case weekly
        case other(minutes: Int?)
    }

    public let identifier: String
    public let displayName: String
    public let availablePrompts: Int?
    public let currentPrompts: Int?
    public let remainingPrompts: Int?
    public let windowMinutes: Int?
    public let usedPercent: Double?
    public let resetsAt: Date?
    public let weeklyTotal: Int?
    public let weeklyUsed: Int?
    public let weeklyRemaining: Int?
    public let weeklyUsedPercent: Double?
    public let weeklyResetsAt: Date?
    public let window: WindowKind

    public init(
        identifier: String,
        displayName: String,
        availablePrompts: Int?,
        currentPrompts: Int?,
        remainingPrompts: Int?,
        windowMinutes: Int?,
        usedPercent: Double?,
        resetsAt: Date?,
        weeklyTotal: Int?,
        weeklyUsed: Int?,
        weeklyRemaining: Int?,
        weeklyUsedPercent: Double?,
        weeklyResetsAt: Date?,
        window: WindowKind)
    {
        self.identifier = identifier
        self.displayName = displayName
        self.availablePrompts = availablePrompts
        self.currentPrompts = currentPrompts
        self.remainingPrompts = remainingPrompts
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.weeklyTotal = weeklyTotal
        self.weeklyUsed = weeklyUsed
        self.weeklyRemaining = weeklyRemaining
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyResetsAt = weeklyResetsAt
        self.window = window
    }
}
