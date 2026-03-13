import CodexBarCore
import Foundation

// MARK: - AdaptiveRefreshScheduler

/// Computes per-provider refresh intervals based on utilisation and recent activity.
///
/// | Level    | Condition                                | Base interval |
/// |----------|------------------------------------------|---------------|
/// | active   | >50 % utilisation or within hysteresis   | 15 s          |
/// | moderate | snapshot updated within the last 2 min   | 60 s          |
/// | idle     | no recent activity                       | 600 s         |
///
/// Hysteresis: once a provider is marked active it stays at the 15 s rate for
/// 120 s after the last activity, preventing rapid bouncing between levels.
///
/// Remote API providers (Claude OAuth, Gemini, Perplexity) have a hard minimum
/// interval of 300 s regardless of activity level, to avoid hitting API rate limits.
/// A 429 response extends that floor to 1800 s and is persisted across relaunches.
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
    /// Backoff after a 429 — persisted across relaunches.
    private static let rateLimitBackoffDuration: TimeInterval = 1800

    /// Providers that call a remote API and must not be polled more often than
    /// their respective minimum intervals regardless of the computed activity level.
    private static let remoteAPIProviders: Set<UsageProvider> = [.claude, .gemini, .perplexity]
    /// Hard floor for Gemini and Perplexity (5 minutes).
    private static let remoteAPIMinimumInterval: TimeInterval = 300
    /// Hard floor for Claude specifically — the /api/oauth/usage endpoint is a private beta
    /// endpoint designed for on-demand queries, not continuous polling. 15 minutes avoids 429s.
    private static let claudeMinimumInterval: TimeInterval = 900

    // MARK: - State

    /// Timestamp of the last time each provider was observed to be at the active level.
    private var lastActiveAt: [UsageProvider: Date] = [:]
    /// When a provider is rate-limited, suppress fast polling until this date.
    /// Persisted in UserDefaults so the backoff survives app relaunches.
    private var rateLimitedUntil: [UsageProvider: Date] = [:]
    /// Timestamp of the last completed refresh attempt for each provider.
    /// Used to gate per-provider refresh so fast local providers don't drag remote API providers.
    private var lastRefreshedAt: [UsageProvider: Date] = [:]

    // MARK: - UserDefaults keys

    private static func rateLimitKey(for provider: UsageProvider) -> String {
        "com.codexbarrt.rateLimit.\(provider.rawValue)"
    }

    // MARK: - Init

    init() {
        // Restore any persisted rate-limit timestamps from previous sessions.
        let now = Date()
        for provider in UsageProvider.allCases {
            let key = Self.rateLimitKey(for: provider)
            if let stored = UserDefaults.standard.object(forKey: key) as? Date, stored > now {
                self.rateLimitedUntil[provider] = stored
            }
        }
    }

    // MARK: - API

    /// Record that `provider` was active right now.
    func recordActivity(for provider: UsageProvider) {
        self.lastActiveAt[provider] = Date()
    }

    /// Record a rate-limit (HTTP 429) for `provider`.  Backs off for
    /// `rateLimitBackoffDuration` seconds and persists the timestamp across relaunches.
    func recordRateLimit(for provider: UsageProvider, now: Date = Date()) {
        let until = now.addingTimeInterval(Self.rateLimitBackoffDuration)
        self.rateLimitedUntil[provider] = until
        self.lastActiveAt.removeValue(forKey: provider)
        UserDefaults.standard.set(until, forKey: Self.rateLimitKey(for: provider))
    }

    /// Returns true if enough time has elapsed since the last refresh for `provider`.
    /// Always returns true on the first call (no prior refresh recorded).
    /// Pass `force: true` for user-initiated refreshes to bypass the gate.
    func shouldRefresh(for provider: UsageProvider, snapshot: UsageSnapshot?, force: Bool = false, now: Date = Date()) -> Bool {
        if force { return true }
        guard let last = self.lastRefreshedAt[provider] else { return true }
        return now.timeIntervalSince(last) >= self.effectiveInterval(for: provider, snapshot: snapshot, now: now)
    }

    /// Record that a refresh attempt completed for `provider` (success or failure).
    func recordRefresh(for provider: UsageProvider, now: Date = Date()) {
        self.lastRefreshedAt[provider] = now
    }

    /// Determine the effective wait interval for a single provider.
    func effectiveInterval(for provider: UsageProvider, snapshot: UsageSnapshot?, now: Date = Date()) -> TimeInterval {
        // Rate-limit backoff takes priority over everything.
        if let until = self.rateLimitedUntil[provider], now < until {
            // During a rate-limit backoff, use the full backoff duration as the interval
            // so the provider isn't polled at all until the backoff expires.
            return until.timeIntervalSince(now)
        }

        let base = self.baseInterval(for: provider, snapshot: snapshot, now: now)

        // Remote API providers have hard floors to avoid hitting API rate limits.
        if provider == .claude {
            return max(base, Self.claudeMinimumInterval)
        }
        if Self.remoteAPIProviders.contains(provider) {
            return max(base, Self.remoteAPIMinimumInterval)
        }
        return base
    }

    /// Return the next global wait interval across all `providers`, capped by `maxInterval`.
    /// Returns `nil` when the caller should not schedule automatic refresh (manual mode).
    func nextInterval(
        providers: [UsageProvider],
        snapshots: [UsageProvider: UsageSnapshot],
        maxInterval: TimeInterval?
    ) -> TimeInterval? {
        guard let ceiling = maxInterval else { return nil }

        var best: TimeInterval = ActivityLevel.idle.interval
        for provider in providers {
            let interval = self.effectiveInterval(for: provider, snapshot: snapshots[provider])
            if interval < best {
                best = interval
            }
        }
        return min(best, ceiling)
    }

    // MARK: - Private

    private func baseInterval(for provider: UsageProvider, snapshot: UsageSnapshot?, now: Date) -> TimeInterval {
        // Hysteresis — keep "active" rate while the window is open.
        if let lastActive = self.lastActiveAt[provider],
           now.timeIntervalSince(lastActive) < Self.hysteresisDuration
        {
            return ActivityLevel.active.interval
        }

        guard let snap = snapshot else { return ActivityLevel.idle.interval }

        // High utilisation → active, start hysteresis clock.
        if let primary = snap.primary, primary.usedPercent > 50 {
            self.lastActiveAt[provider] = now
            return ActivityLevel.active.interval
        }

        // Snapshot refreshed recently → moderate.
        if now.timeIntervalSince(snap.updatedAt) < Self.moderateWindowDuration {
            return ActivityLevel.moderate.interval
        }

        return ActivityLevel.idle.interval
    }
}
