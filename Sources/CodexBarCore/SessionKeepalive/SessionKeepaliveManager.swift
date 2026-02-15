import Foundation

#if os(macOS)

/// Unified session keepalive manager for all providers.
///
/// This manager coordinates automatic session refresh across multiple providers,
/// preventing session expiration and authentication failures during idle periods.
///
/// **Design Principles:**
/// - Non-invasive: Runs alongside existing provider-specific keepalive systems
/// - Extensible: Easy to add new providers with custom refresh strategies
/// - Configurable: Per-provider settings with sensible defaults
/// - Safe: Rate limiting, error handling, and automatic disable on repeated failures
///
/// **Usage:**
/// ```swift
/// let manager = SessionKeepaliveManager.shared
/// await manager.start(provider: .augment, config: .augmentDefault)
/// await manager.start(provider: .claude, config: .claudeDefault)
/// ```
@MainActor
public final class SessionKeepaliveManager {
    // MARK: - Singleton

    public static let shared = SessionKeepaliveManager()

    // MARK: - State

    /// Active keepalive tasks per provider.
    private var scheduledTasks: [UsageProvider: Task<Void, Never>] = [:]

    /// Current configuration per provider.
    private var configs: [UsageProvider: KeepaliveConfig] = [:]

    /// Last refresh attempt timestamp per provider.
    private var lastRefreshAttempt: [UsageProvider: Date] = [:]

    /// Last successful refresh timestamp per provider.
    private var lastSuccessfulRefresh: [UsageProvider: Date] = [:]

    /// Consecutive failure count per provider.
    private var consecutiveFailures: [UsageProvider: Int] = [:]

    /// Whether a refresh is currently in progress per provider.
    private var isRefreshing: Set<UsageProvider> = []

    /// Optional logger for debugging.
    private let logger: ((String) -> Void)?

    // MARK: - Initialization

    private init(logger: ((String) -> Void)? = nil) {
        self.logger = logger
    }

    deinit {
        for task in self.scheduledTasks.values {
            task.cancel()
        }
    }

    // MARK: - Public API

    /// Start keepalive for a provider with the given configuration.
    ///
    /// If keepalive is already running for this provider, it will be stopped and restarted
    /// with the new configuration.
    ///
    /// - Parameters:
    ///   - provider: The provider to keep alive
    ///   - config: Keepalive configuration (mode, intervals, etc.)
    public func start(provider: UsageProvider, config: KeepaliveConfig) {
        guard config.enabled else {
            self.log(provider, "Keepalive disabled in config, not starting")
            return
        }

        // Stop existing task if running
        if self.scheduledTasks[provider] != nil {
            self.log(provider, "Stopping existing keepalive before restart")
            self.stop(provider: provider)
        }

        self.configs[provider] = config
        self.consecutiveFailures[provider] = 0

        self.log(provider, "🚀 Starting session keepalive: \(config)")

        // Create background task based on mode
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            await self.runKeepaliveLoop(provider: provider, config: config)
        }

        self.scheduledTasks[provider] = task
        self.log(provider, "✅ Keepalive task started")
    }

    /// Stop keepalive for a provider.
    ///
    /// - Parameter provider: The provider to stop keepalive for
    public func stop(provider: UsageProvider) {
        self.log(provider, "Stopping session keepalive")
        self.scheduledTasks[provider]?.cancel()
        self.scheduledTasks.removeValue(forKey: provider)
        self.configs.removeValue(forKey: provider)
        self.isRefreshing.remove(provider)
    }

    /// Force an immediate refresh for a provider (bypasses rate limiting).
    ///
    /// - Parameter provider: The provider to refresh
    public func forceRefresh(provider: UsageProvider) async {
        self.log(provider, "Force refresh requested")
        await self.performRefresh(provider: provider, forced: true)
    }

    /// Get the last successful refresh time for a provider.
    ///
    /// - Parameter provider: The provider to query
    /// - Returns: The last successful refresh date, or nil if never refreshed
    public func lastRefreshTime(for provider: UsageProvider) -> Date? {
        self.lastSuccessfulRefresh[provider]
    }

    /// Get the current configuration for a provider.
    ///
    /// - Parameter provider: The provider to query
    /// - Returns: The current config, or nil if not configured
    public func configuration(for provider: UsageProvider) -> KeepaliveConfig? {
        self.configs[provider]
    }

    // MARK: - Private Implementation

    /// Main keepalive loop for a provider.
    private func runKeepaliveLoop(provider: UsageProvider, config: KeepaliveConfig) async {
        while !Task.isCancelled {
            // Calculate next check interval based on mode
            let checkInterval = self.calculateCheckInterval(for: config)

            // Wait for the check interval
            try? await Task.sleep(for: .seconds(checkInterval))

            // Check if we should refresh
            await self.checkAndRefreshIfNeeded(provider: provider, config: config)
        }
    }

    /// Calculate the check interval based on the keepalive mode.
    private func calculateCheckInterval(for config: KeepaliveConfig) -> TimeInterval {
        switch config.mode {
        case .interval(let seconds):
            return seconds
        case .daily:
            // Check every hour for daily mode
            return 3600
        case .beforeExpiry:
            // Check every 5 minutes for expiry-based mode
            return 300
        }
    }

    /// Check if refresh is needed and perform it if so.
    private func checkAndRefreshIfNeeded(provider: UsageProvider, config: KeepaliveConfig) async {
        guard !self.isRefreshing.contains(provider) else {
            self.log(provider, "Refresh already in progress, skipping check")
            return
        }

        // Rate limit: don't refresh too frequently
        if let lastAttempt = self.lastRefreshAttempt[provider] {
            let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
            if timeSinceLastAttempt < config.minRefreshInterval {
                self.log(
                    provider,
                    "Skipping refresh (last attempt \(Int(timeSinceLastAttempt))s ago, min interval: \(Int(config.minRefreshInterval))s)")
                return
            }
        }

        // Check if we should refresh based on mode
        let shouldRefresh = await self.shouldRefreshSession(provider: provider, config: config)
        if shouldRefresh {
            await self.performRefresh(provider: provider, forced: false)
        }
    }

    /// Determine if a session should be refreshed based on the mode.
    private func shouldRefreshSession(provider: UsageProvider, config: KeepaliveConfig) async -> Bool {
        switch config.mode {
        case .interval:
            // For interval mode, always refresh when check interval elapses
            return true

        case .daily(let hour, let minute):
            // For daily mode, check if we're at the scheduled time
            let now = Date()
            let calendar = Calendar.current
            let components = calendar.dateComponents([.hour, .minute], from: now)

            guard let currentHour = components.hour, let currentMinute = components.minute else {
                return false
            }

            // Check if we're within 5 minutes of the scheduled time
            let scheduledMinutes = hour * 60 + minute
            let currentMinutes = currentHour * 60 + currentMinute
            let diff = abs(scheduledMinutes - currentMinutes)

            if diff <= 5 {
                // Check if we already refreshed today
                if let lastRefresh = self.lastSuccessfulRefresh[provider] {
                    let isSameDay = calendar.isDate(lastRefresh, inSameDayAs: now)
                    return !isSameDay
                }
                return true
            }
            return false

        case .beforeExpiry:
            // For expiry-based mode, delegate to provider-specific logic
            // This will be implemented per-provider in Phase 2
            self.log(provider, "beforeExpiry mode requires provider-specific implementation")
            return false
        }
    }

    /// Perform the actual session refresh.
    private func performRefresh(provider: UsageProvider, forced: Bool) async {
        self.isRefreshing.insert(provider)
        self.lastRefreshAttempt[provider] = Date()
        defer { self.isRefreshing.remove(provider) }

        self.log(provider, forced ? "Performing forced session refresh..." : "Performing automatic session refresh...")

        // Provider-specific refresh logic will be implemented in Phase 2
        // For now, just log that we would refresh
        self.log(provider, "⚠️ Provider-specific refresh not yet implemented")

        // Simulate success for now
        self.lastSuccessfulRefresh[provider] = Date()
        self.consecutiveFailures[provider] = 0
        self.log(provider, "✅ Session refresh completed (placeholder)")
    }

    private static let log = CodexBarLog.logger("session-keepalive")

    /// Log a message with provider context.
    private func log(_ provider: UsageProvider, _ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        let fullMessage = "[\(timestamp)] [SessionKeepalive:\(provider.rawValue)] \(message)"
        self.logger?(fullMessage)
        Self.log.debug(fullMessage)
    }
}

#endif

