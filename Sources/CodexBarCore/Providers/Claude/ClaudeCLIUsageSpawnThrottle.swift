import Foundation

/// Bounds how often background refreshes may relaunch the Claude CLI for a usage probe (#2916).
/// Each CLI usage fetch spawns the full ~280 MB Claude Code binary, so background ticks reuse the
/// last successful CLI result within a floor interval instead of respawning. User-initiated
/// refreshes always spawn so the manual Refresh action stays fresh.
enum ClaudeCLIUsageSpawnThrottle {
    struct Key: Hashable {
        let binary: String
        let accountScope: String
        let useWebExtras: Bool
        let includePrepaidBalance: Bool
    }

    struct Entry {
        let result: ProviderFetchResult
        let recordedAt: Date
    }

    /// Matches the repo's existing 15-minute floor precedent for expensive local work
    /// (`UsageStore.minimumTokenFetchTTL`).
    static let minimumBackgroundSpawnInterval: TimeInterval = 15 * 60

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Key: Entry] = [:]

        func insert(_ entry: Entry, for key: Key) {
            self.lock.withLock {
                self.entries[key] = entry
            }
        }

        func lookup(_ key: Key, now: Date) -> Entry? {
            self.lock.withLock {
                guard let entry = self.entries[key] else { return nil }
                guard now.timeIntervalSince(entry.recordedAt) < minimumBackgroundSpawnInterval,
                      !ClaudeCLIUsageSpawnThrottle.anyWindowHasReset(in: entry.result.usage, now: now)
                else {
                    self.entries.removeValue(forKey: key)
                    return nil
                }
                return entry
            }
        }

        func removeAll() {
            self.lock.withLock {
                self.entries.removeAll()
            }
        }
    }

    private static let log = CodexBarLog.logger(LogCategories.provider(.claude, scope: "usage"))
    private static let sharedStore = Store()
    @TaskLocal private static var storeOverrideForTesting: Store?
    @TaskLocal private static var nowOverrideForTesting: (@Sendable () -> Date)?

    private static var store: Store {
        self.storeOverrideForTesting ?? self.sharedStore
    }

    private static var now: Date {
        self.nowOverrideForTesting?() ?? Date()
    }

    /// nil when the Claude profile exposes no stable account identity
    /// (`ClaudeAccountProfile.identifiedSessionScope` returns nil) — such profiles are never cached.
    static func key(
        binary: String,
        environment: [String: String],
        useWebExtras: Bool,
        includePrepaidBalance: Bool) -> Key?
    {
        guard let accountScope = ClaudeAccountProfile.identifiedSessionScope(environment: environment) else {
            return nil
        }
        return Key(
            binary: binary,
            accountScope: accountScope,
            useWebExtras: useWebExtras,
            includePrepaidBalance: includePrepaidBalance)
    }

    /// Returns the cached result when it is younger than `minimumBackgroundSpawnInterval`.
    /// A stale or missing entry returns nil (and a stale entry is removed).
    static func cachedResult(for key: Key) -> ProviderFetchResult? {
        let now = self.now
        guard let entry = self.store.lookup(key, now: now) else { return nil }
        let ageSeconds = max(0, now.timeIntervalSince(entry.recordedAt))
        Self.log.debug(
            "Reusing cached Claude CLI usage result",
            metadata: ["ageSeconds": "\(ageSeconds)"])
        return entry.result
    }

    static func record(_ result: ProviderFetchResult, for key: Key) {
        self.store.insert(Entry(result: result, recordedAt: self.now), for: key)
    }

    /// A cached result is unusable once any of its rate windows crosses its reset boundary: the
    /// session/weekly percentages then describe the previous window, and the reset-boundary refresh
    /// scheduler exists precisely to publish the post-reset state promptly.
    static func anyWindowHasReset(in usage: UsageSnapshot, now: Date) -> Bool {
        let windows = [usage.primary, usage.secondary, usage.tertiary]
            .compactMap(\.self)
            + (usage.extraRateWindows?.map(\.window) ?? [])
        return windows.contains { window in
            guard let resetsAt = window.resetsAt else { return false }
            return resetsAt <= now
        }
    }

    #if DEBUG
    static func withIsolatedStoreForTesting<T>(
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$storeOverrideForTesting.withValue(Store()) {
            try await operation()
        }
    }

    static func withNowOverrideForTesting<T>(
        _ now: @escaping @Sendable () -> Date,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$nowOverrideForTesting.withValue(now) {
            try await operation()
        }
    }
    #endif
}
