import CodexBarCore
import Foundation

// MARK: - AdaptiveRefreshScheduler

/// Computes per-provider refresh intervals based on utilisation and recent activity.
///
/// | Level    | Condition                                | Interval |
/// |----------|------------------------------------------|----------|
/// | active   | >50 % utilisation or within hysteresis   | 15 s     |
/// | moderate | snapshot updated within the last 2 min   | 60 s     |
/// | idle     | no recent activity                       | 600 s    |
///
/// Hysteresis: once a provider is marked active it stays at the 15 s rate for
/// 120 s after the last activity, preventing rapid bouncing between levels.
@MainActor
final class AdaptiveRefreshScheduler {
    // MARK: - ActivityLevel

    enum ActivityLevel {
        case active
        case moderate
        case idle

        var interval: TimeInterval {
            switch self {
            case .active: 15
            case .moderate: 60
            case .idle: 600
            }
        }
    }

    // MARK: - Constants

    private static let hysteresisDuration: TimeInterval = 120
    private static let moderateWindowDuration: TimeInterval = 120
    /// How long to back off after receiving a 429 rate-limit error.
    private static let rateLimitBackoffDuration: TimeInterval = 300

    // MARK: - State

    /// Timestamp of the last time each provider was observed to be at the active level.
    private var lastActiveAt: [UsageProvider: Date] = [:]
    /// When a provider is rate-limited, suppress fast polling until this date.
    private var rateLimitedUntil: [UsageProvider: Date] = [:]

    // MARK: - API

    /// Record that `provider` was active right now (called after a fetch that
    /// found >50 % utilisation so hysteresis keeps the fast rate alive).
    func recordActivity(for provider: UsageProvider) {
        self.lastActiveAt[provider] = Date()
    }

    /// Record a rate-limit (HTTP 429) error for `provider`.  The scheduler will
    /// force the idle interval for at least `rateLimitBackoffDuration` seconds.
    func recordRateLimit(for provider: UsageProvider, now: Date = Date()) {
        self.rateLimitedUntil[provider] = now.addingTimeInterval(Self.rateLimitBackoffDuration)
        // Also clear the hysteresis so we don't immediately re-enter active mode.
        self.lastActiveAt.removeValue(forKey: provider)
    }

    /// Determine the activity level for a single provider.
    func activityLevel(for provider: UsageProvider, snapshot: UsageSnapshot?) -> ActivityLevel {
        let now = Date()

        // Rate-limit backoff — force idle regardless of utilisation.
        if let until = self.rateLimitedUntil[provider], now < until {
            return .idle
        }

        // Hysteresis — keep "active" rate while the window is open.
        if let lastActive = self.lastActiveAt[provider],
           now.timeIntervalSince(lastActive) < Self.hysteresisDuration
        {
            return .active
        }

        guard let snap = snapshot else { return .idle }

        // High utilisation → active and start hysteresis clock.
        if let primary = snap.primary, primary.usedPercent > 50 {
            self.lastActiveAt[provider] = now
            return .active
        }

        // Snapshot was refreshed recently → moderate.
        if now.timeIntervalSince(snap.updatedAt) < Self.moderateWindowDuration {
            return .moderate
        }

        return .idle
    }

    /// Return the next wait interval across all `providers`, capped by `maxInterval`
    /// (the user-configured refresh frequency ceiling).  Returns `nil` when the
    /// caller should not schedule any automatic refresh (manual mode).
    func nextInterval(
        providers: [UsageProvider],
        snapshots: [UsageProvider: UsageSnapshot],
        maxInterval: TimeInterval?
    ) -> TimeInterval? {
        guard let ceiling = maxInterval else { return nil }

        var best: TimeInterval = ActivityLevel.idle.interval
        for provider in providers {
            let level = self.activityLevel(for: provider, snapshot: snapshots[provider])
            if level.interval < best {
                best = level.interval
            }
        }
        // Never exceed the user's configured ceiling, but allow going faster.
        return min(best, ceiling)
    }
}
