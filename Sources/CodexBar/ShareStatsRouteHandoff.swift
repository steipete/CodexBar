import CodexBarCore
import Foundation

struct ShareStatsRouteHandoff: Equatable {
    /// A queued route is a response to a click. If it cannot be delivered while that click is
    /// still the user's intent, it is stale: delivering it later pops an unrequested window.
    static let maximumAge: TimeInterval = 60

    private var pending: (route: ShareStatsRoute, enqueuedAt: Date)?

    var pendingRoute: ShareStatsRoute? {
        self.pending?.route
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pending?.route == rhs.pending?.route && lhs.pending?.enqueuedAt == rhs.pending?.enqueuedAt
    }

    mutating func enqueue(_ route: ShareStatsRoute, at date: Date = Date()) {
        // There is one idempotent destination; retain it across cold launch and coalesce repeats.
        self.pending = (route, date)
    }

    @discardableResult
    mutating func deliverIfPossible(
        now: Date = Date(),
        _ deliver: (ShareStatsRoute) -> Bool) -> Bool
    {
        guard let pending = self.pending else { return false }
        guard now.timeIntervalSince(pending.enqueuedAt) <= Self.maximumAge else {
            self.pending = nil
            return false
        }
        guard deliver(pending.route) else { return false }
        self.pending = nil
        return true
    }
}
