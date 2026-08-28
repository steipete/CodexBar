import Foundation

public struct RateWindowBindingQuotaProjection: Sendable, Equatable {
    public let usedPercent: Double
    public let resetsAt: Date?
    public let resetDescription: String?

    public init(usedPercent: Double, resetsAt: Date?, resetDescription: String?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }
}

extension RateWindow {
    /// The primary slot is the session lane even when a provider omits duration metadata.
    private static let sessionWindowMinutes = 5 * 60

    /// Projects the displayed primary percentage and reset through exhausted longer binding lanes.
    /// Raw primary detail remains owned by the primary lane and is not replaced by this projection.
    public static func bindingQuotaProjection(
        primary: RateWindow,
        bindingLanes: [RateWindow],
        now: Date) -> RateWindowBindingQuotaProjection?
    {
        let primaryMinutes = primary.windowMinutes ?? Self.sessionWindowMinutes
        let exhaustedBindingLanes = bindingLanes.filter { lane in
            guard let minutes = lane.windowMinutes, minutes > primaryMinutes else { return false }
            return Self.isActivelyExhausted(lane, now: now)
        }
        guard !exhaustedBindingLanes.isEmpty else { return nil }

        var blockers = exhaustedBindingLanes
        if Self.isActivelyExhausted(primary, now: now) {
            blockers.append(primary)
        }
        let reset = Self.effectiveReset(blockers: blockers)
        return RateWindowBindingQuotaProjection(
            usedPercent: 100,
            resetsAt: reset.date,
            resetDescription: reset.description)
    }

    private static func isActivelyExhausted(_ window: RateWindow, now: Date) -> Bool {
        guard window.remainingPercent <= 0 else { return false }
        return window.resetsAt.map { $0 > now } ?? true
    }

    /// All exhausted gates must reset before the primary lane is usable again. Do not promise an
    /// earlier known reset when another active blocker has no comparable reset date.
    private static func effectiveReset(blockers: [RateWindow]) -> (date: Date?, description: String?) {
        let unknownResetBlockers = blockers.filter { $0.resetsAt == nil }
        if !unknownResetBlockers.isEmpty {
            let description = unknownResetBlockers[0].resetDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard blockers.count == 1, let description, !description.isEmpty else { return (nil, nil) }
            return (nil, description)
        }

        let latest = blockers.max { lhs, rhs in
            guard let lhsReset = lhs.resetsAt, let rhsReset = rhs.resetsAt else { return false }
            return lhsReset < rhsReset
        }
        return (latest?.resetsAt, nil)
    }
}
