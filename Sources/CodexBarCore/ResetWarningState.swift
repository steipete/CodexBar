import Foundation

public struct ResetWarning: Equatable, Sendable {
    public let providerID: UsageProvider
    public let windowKind: WindowKind
    public let remainingPercent: Double
    public let resetsAt: Date
    public let hoursUntilReset: Double

    public enum WindowKind: String, Sendable {
        case session
        case weekly
    }

    public init(
        providerID: UsageProvider,
        windowKind: WindowKind,
        remainingPercent: Double,
        resetsAt: Date,
        hoursUntilReset: Double)
    {
        self.providerID = providerID
        self.windowKind = windowKind
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.hoursUntilReset = hoursUntilReset
    }
}

public enum ResetWarningEvaluator {
    public static let minimumRemainingPercent: Double = 20
    public static let defaultWarningHours: Int = 8
    public static let notificationCooldownHours: Double = 1

    public static func evaluate(
        provider: UsageProvider,
        window: RateWindow,
        windowKind: ResetWarning.WindowKind,
        warningHours: Int,
        minimumRemainingPercent: Double = ResetWarningEvaluator.minimumRemainingPercent,
        now: Date = .init()) -> ResetWarning?
    {
        guard let resetsAt = window.resetsAt else { return nil }
        let secondsUntilReset = resetsAt.timeIntervalSince(now)
        guard secondsUntilReset > 0 else { return nil }

        let hoursUntilReset = secondsUntilReset / 3600
        let warningWindow = Double(warningHours)

        guard hoursUntilReset <= warningWindow else { return nil }

        let remaining = window.remainingPercent
        guard remaining >= minimumRemainingPercent else { return nil }

        return ResetWarning(
            providerID: provider,
            windowKind: windowKind,
            remainingPercent: remaining,
            resetsAt: resetsAt,
            hoursUntilReset: hoursUntilReset)
    }

    public static func shouldNotify(
        warning: ResetWarning,
        lastNotifiedAt: Date?,
        now: Date = .init()) -> Bool
    {
        guard let lastNotifiedAt else { return true }
        let cooldownSeconds = Self.notificationCooldownHours * 3600
        return now.timeIntervalSince(lastNotifiedAt) >= cooldownSeconds
    }
}
