import CodexBarCore
import Foundation

/// Reset-time backfill for Codex rate windows: rebuilds raw snapshot slots from cached lane data so
/// missing reset timestamps survive refreshes without disturbing fresh quota values.
extension UsageStore {
    nonisolated static func codexBackfillingResetWindows(
        _ snapshot: UsageSnapshot,
        from cached: UsageSnapshot) -> UsageSnapshot
    {
        let primary = self.codexBackfilledSlotWindow(
            slotWindow: snapshot.primary,
            lane: .session,
            snapshot: snapshot,
            cached: cached)
        let secondary = self.codexBackfilledSlotWindow(
            slotWindow: snapshot.secondary,
            lane: .weekly,
            snapshot: snapshot,
            cached: cached)
        guard primary != snapshot.primary || secondary != snapshot.secondary else { return snapshot }
        return snapshot.with(primary: primary, secondary: secondary)
    }

    /// Rebuilds one raw snapshot slot during reset backfill. Monthly-classified windows live outside
    /// the session/weekly lane lookup, so a fresh 30-day window must be preserved in place (with its
    /// own reset backfill) instead of being dropped or overwritten by a stale cached lane window.
    private nonisolated static func codexBackfilledSlotWindow(
        slotWindow: RateWindow?,
        lane: CodexConsumerProjection.RateLane,
        snapshot: UsageSnapshot,
        cached: UsageSnapshot) -> RateWindow?
    {
        if let slotWindow, slotWindow.windowMinutes == CodexConsumerProjection.monthlyWindowMinutes {
            let cachedMonthly = [cached.primary, cached.secondary, cached.tertiary]
                .compactMap(\.self)
                .first { $0.windowMinutes == CodexConsumerProjection.monthlyWindowMinutes }
            return self.codexBackfillingResetWindow(slotWindow, from: cachedMonthly)
        }
        return self.codexBackfillingResetWindow(
            CodexConsumerProjection.sourceRateWindow(for: lane, snapshot: snapshot),
            from: CodexConsumerProjection.sourceRateWindow(for: lane, snapshot: cached))
    }

    nonisolated static func codexMergedResetBackfillSnapshot(
        _ snapshots: [UsageSnapshot],
        now: Date = Date()) -> UsageSnapshot?
    {
        var primary = self.codexPreferredResetBackfillWindow(
            snapshots.enumerated().compactMap { index, snapshot in
                CodexConsumerProjection.sourceRateWindow(for: .session, snapshot: snapshot)
                    .map { (window: $0, updatedAt: snapshot.updatedAt, priority: index) }
            },
            now: now)
        var secondary = self.codexPreferredResetBackfillWindow(
            snapshots.enumerated().compactMap { index, snapshot in
                CodexConsumerProjection.sourceRateWindow(for: .weekly, snapshot: snapshot)
                    .map { (window: $0, updatedAt: snapshot.updatedAt, priority: index) }
            },
            now: now)
        let monthly = self.codexPreferredResetBackfillWindow(
            snapshots.enumerated().compactMap { index, snapshot in
                Self.monthlyRateWindow(in: snapshot)
                    .map { (window: $0, updatedAt: snapshot.updatedAt, priority: index) }
            },
            now: now)
        if let monthly, let monthlyReset = monthly.resetsAt {
            if primary == nil {
                primary = monthly
            } else if secondary == nil {
                secondary = monthly
            } else if let primaryReset = primary?.resetsAt, monthlyReset > primaryReset {
                primary = monthly
            } else if let secondaryReset = secondary?.resetsAt, monthlyReset > secondaryReset {
                secondary = monthly
            }
        }
        guard primary != nil || secondary != nil else { return nil }
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: snapshots.map(\.updatedAt).max() ?? now)
    }

    private nonisolated static func monthlyRateWindow(in snapshot: UsageSnapshot) -> RateWindow? {
        [snapshot.primary, snapshot.secondary, snapshot.tertiary]
            .compactMap(\.self)
            .first { $0.windowMinutes == CodexConsumerProjection.monthlyWindowMinutes }
    }

    private nonisolated static func codexPreferredResetBackfillWindow(
        _ windows: [(window: RateWindow, updatedAt: Date, priority: Int)],
        now: Date) -> RateWindow?
    {
        windows
            .filter { ($0.window.resetsAt ?? .distantPast) > now }
            .max { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt < rhs.updatedAt
                }
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                let lhsReset = lhs.window.resetsAt ?? .distantPast
                let rhsReset = rhs.window.resetsAt ?? .distantPast
                if lhsReset != rhsReset {
                    return lhsReset < rhsReset
                }
                return (lhs.window.windowMinutes ?? 0) < (rhs.window.windowMinutes ?? 0)
            }
            .map(\.window)
    }

    private nonisolated static func codexBackfillingResetWindow(
        _ window: RateWindow?,
        from cached: RateWindow?) -> RateWindow?
    {
        guard let cached,
              let resetsAt = cached.resetsAt,
              resetsAt > Date()
        else {
            return window
        }
        if let window {
            return window.backfillingResetTime(from: cached)
        }
        guard let windowMinutes = cached.windowMinutes, windowMinutes > 0 else { return nil }
        return RateWindow(
            usedPercent: cached.usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: cached.resetDescription)
    }
}
