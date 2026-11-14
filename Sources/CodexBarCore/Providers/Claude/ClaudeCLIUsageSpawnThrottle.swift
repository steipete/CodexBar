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

    /// What a background refresh does instead of launching Claude while no session window is running.
    enum IdleSession {
        /// The last reading with elapsed windows rolled over.
        case usage(UsageSnapshot)
        /// The last probe for this account failed; surface that instead of a rolled-over reading.
        case failure(any Error)
    }

    /// Idle state belongs to the CLI account, not to the strategy flags in `Key`: the owner-CLI recovery pass
    /// probes without web extras, yet must see the reading the main pass recorded.
    private struct Account: Hashable {
        let binary: String
        let accountScope: String

        init(_ key: Key) {
            self.binary = key.binary
            self.accountScope = key.accountScope
        }
    }

    /// Matches the repo's existing 15-minute floor precedent for expensive local work
    /// (`UsageStore.minimumTokenFetchTTL`).
    static let minimumBackgroundSpawnInterval: TimeInterval = 15 * 60

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Key: Entry] = [:]
        private var failures: [Account: (error: any Error, recordedAt: Date)] = [:]

        func insert(_ entry: Entry, for key: Key) {
            self.lock.withLock {
                self.entries[key] = entry
                self.failures.removeValue(forKey: Account(key))
            }
        }

        func recordFailure(_ error: any Error, for key: Key, at date: Date) {
            self.lock.withLock {
                self.failures[Account(key)] = (error: error, recordedAt: date)
            }
        }

        /// The newest reading for the key's CLI account under any strategy flags, plus its last failure.
        func latestForAccount(of key: Key)
            -> (entry: Entry, failure: (error: any Error, recordedAt: Date)?)?
        {
            self.lock.withLock {
                let account = Account(key)
                let newest = self.entries
                    .filter { Account($0.key) == account }
                    .max { $0.value.recordedAt < $1.value.recordedAt }
                return newest.map { (entry: $0.value, failure: self.failures[account]) }
            }
        }

        func lookup(_ key: Key, now: Date) -> Entry? {
            self.lock.withLock {
                guard let entry = self.entries[key] else { return nil }
                // Expired entries stay stored: `idleSession` still needs the last reading after its
                // session window resets. Each key holds one entry, so the store stays small.
                guard now.timeIntervalSince(entry.recordedAt) < minimumBackgroundSpawnInterval,
                      !ClaudeCLIUsageSpawnThrottle.anyWindowHasReset(in: entry.result.usage, now: now)
                else {
                    return nil
                }
                return entry
            }
        }

        func removeAll() {
            self.lock.withLock {
                self.entries.removeAll()
                self.failures.removeAll()
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

    /// Returns the cached result when it is younger than `minimumBackgroundSpawnInterval` and none of its windows
    /// has reset. Otherwise returns nil; the entry stays stored for `idleSession`.
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

    /// Remembers a failed probe so idle refreshes surface it rather than a rolled-over 0%. The stored reading is
    /// kept: dropping it would let the next background refresh launch Claude with no window running.
    static func recordFailure(_ error: any Error, for key: Key) {
        self.store.recordFailure(error, for: key, at: self.now)
    }

    /// Background only: reuse the last CLI reading after its session resets while this profile has no newer activity.
    /// A `/usage` startup can open a new five-hour window, so defer probing until local activity or manual Refresh.
    /// Preserve failures newer than the reset and authentication failures that still require user action.
    static func idleSession(
        for key: Key,
        environment: [String: String],
        fileManager: FileManager = .default) -> IdleSession?
    {
        let now = self.now
        guard let latest = self.store.latestForAccount(of: key),
              let sessionResetsAt = latest.entry.result.usage.primary?.resetsAt,
              sessionResetsAt <= now
        else { return nil }
        guard !ClaudeLocalSessionActivity.hasActivity(
            since: sessionResetsAt,
            environment: environment,
            fileManager: fileManager)
        else { return nil }
        Self.log.debug(
            "Skipping Claude CLI usage spawn while no session window is running",
            metadata: ["sessionResetAgeSeconds": "\(Int(now.timeIntervalSince(sessionResetsAt)))"])
        // Older transient failures do not block rollover. Authentication failures remain relevant across resets
        // and must stay visible until a successful probe clears them.
        if let failure = latest.failure,
           failure.recordedAt >= sessionResetsAt || ClaudeUsageFetcher.isCLIAuthenticationError(failure.error)
        {
            return .failure(failure.error)
        }
        return .usage(self.rollingOverElapsedWindows(in: latest.entry.result.usage, now: now))
    }

    /// Roll elapsed windows to 0% with no reset time, preserving the last real reading's timestamp.
    /// Keep lane classification so session-restored notifications can observe the reset.
    static func rollingOverElapsedWindows(in usage: UsageSnapshot, now: Date) -> UsageSnapshot {
        func rolledOver(_ window: RateWindow?) -> RateWindow? {
            guard let window, let resetsAt = window.resetsAt, resetsAt <= now else { return window }
            return RateWindow(
                usedPercent: 0,
                windowMinutes: window.windowMinutes,
                resetsAt: nil,
                resetDescription: nil,
                quotaLimit: window.quotaLimit,
                quotaUnit: window.quotaUnit,
                nextRegenPercent: window.nextRegenPercent,
                isSyntheticPlaceholder: window.isSyntheticPlaceholder,
                title: window.title)
        }
        let extraRateWindows = usage.extraRateWindows?.map { named in
            guard let window = rolledOver(named.window), window != named.window else { return named }
            return NamedRateWindow(id: named.id, title: named.title, window: window, usageKnown: named.usageKnown)
        }
        return usage.replacing(
            primary: .value(rolledOver(usage.primary)),
            secondary: .value(rolledOver(usage.secondary)),
            tertiary: .value(rolledOver(usage.tertiary)),
            extraRateWindows: .value(extraRateWindows))
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
