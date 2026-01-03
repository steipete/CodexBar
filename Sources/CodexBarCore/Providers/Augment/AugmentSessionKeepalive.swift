import Foundation

#if os(macOS)

/// Manages automatic session keepalive for Augment to prevent cookie expiration.
///
/// This actor monitors cookie expiration and proactively refreshes the session
/// before cookies expire, ensuring uninterrupted access to Augment APIs.
@MainActor
public final class AugmentSessionKeepalive {
    // MARK: - Configuration

    /// How often to check if session needs refresh (default: 5 minutes)
    private let checkInterval: TimeInterval = 300

    /// Refresh session this many seconds before cookie expiration (default: 5 minutes)
    private let refreshBufferSeconds: TimeInterval = 300

    /// Minimum time between refresh attempts (default: 2 minutes)
    private let minRefreshInterval: TimeInterval = 120

    /// Maximum time to wait for session refresh (default: 30 seconds)
    private let refreshTimeout: TimeInterval = 30

    // MARK: - State

    private var timerTask: Task<Void, Never>?
    private var lastRefreshAttempt: Date?
    private var lastSuccessfulRefresh: Date?
    private var isRefreshing = false
    private let logger: ((String) -> Void)?

    // MARK: - Initialization

    public init(logger: ((String) -> Void)? = nil) {
        self.logger = logger
    }

    deinit {
        self.timerTask?.cancel()
    }

    // MARK: - Public API

    /// Start the automatic session keepalive timer
    public func start() {
        guard self.timerTask == nil else {
            self.log("Keepalive already running")
            return
        }

        self.log("🚀 Starting Augment session keepalive")
        self.log("   - Check interval: \(Int(self.checkInterval))s (every 5 minutes)")
        self.log("   - Refresh buffer: \(Int(self.refreshBufferSeconds))s (5 minutes before expiry)")
        self.log("   - Min refresh interval: \(Int(self.minRefreshInterval))s (2 minutes)")

        self.timerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.checkInterval ?? 300))
                await self?.checkAndRefreshIfNeeded()
            }
        }

        self.log("✅ Keepalive timer started successfully")
    }

    /// Stop the automatic session keepalive timer
    public func stop() {
        self.log("Stopping Augment session keepalive")
        self.timerTask?.cancel()
        self.timerTask = nil
    }

    /// Manually trigger a session refresh (bypasses rate limiting)
    public func forceRefresh() async {
        self.log("Force refresh requested")
        await self.performRefresh(forced: true)
    }

    // MARK: - Private Implementation

    private func checkAndRefreshIfNeeded() async {
        guard !self.isRefreshing else {
            self.log("Refresh already in progress, skipping check")
            return
        }

        // Rate limit: don't refresh too frequently
        if let lastAttempt = self.lastRefreshAttempt {
            let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
            if timeSinceLastAttempt < self.minRefreshInterval {
                self.log("Skipping refresh (last attempt \(Int(timeSinceLastAttempt))s ago, min interval: \(Int(self.minRefreshInterval))s)")
                return
            }
        }

        // Check if cookies are about to expire
        let shouldRefresh = await self.shouldRefreshSession()
        if shouldRefresh {
            await self.performRefresh(forced: false)
        }
    }

    private func shouldRefreshSession() async -> Bool {
        do {
            let session = try AugmentCookieImporter.importSession(logger: self.logger)

            // Find the earliest expiration date among session cookies
            let expirationDates = session.cookies.compactMap { $0.expiresDate }

            guard !expirationDates.isEmpty else {
                // Session cookies (no expiration) - refresh periodically
                if let lastRefresh = self.lastSuccessfulRefresh {
                    let timeSinceRefresh = Date().timeIntervalSince(lastRefresh)
                    // Refresh every 30 minutes for session cookies
                    if timeSinceRefresh > 1800 {
                        self.log("Session cookies need periodic refresh (\(Int(timeSinceRefresh))s since last refresh)")
                        return true
                    }
                } else {
                    // Never refreshed - do it now
                    self.log("Session cookies found but never refreshed")
                    return true
                }
                return false
            }

            let earliestExpiration = expirationDates.min()!
            let timeUntilExpiration = earliestExpiration.timeIntervalSinceNow

            if timeUntilExpiration < self.refreshBufferSeconds {
                self.log("Session expires in \(Int(timeUntilExpiration))s (threshold: \(Int(self.refreshBufferSeconds))s) - refresh needed")
                return true
            } else {
                self.log("Session healthy (expires in \(Int(timeUntilExpiration))s)")
                return false
            }
        } catch {
            self.log("Failed to check session: \(error.localizedDescription)")
            return false
        }
    }

    private func performRefresh(forced: Bool) async {
        self.isRefreshing = true
        self.lastRefreshAttempt = Date()
        defer { self.isRefreshing = false }

        self.log(forced ? "Performing forced session refresh..." : "Performing automatic session refresh...")

        do {
            // Step 1: Ping the session endpoint to trigger cookie refresh
            let refreshed = try await self.pingSessionEndpoint()

            if refreshed {
                // Step 2: Re-import cookies from browser
                try await Task.sleep(for: .seconds(1)) // Brief delay for browser to update cookies
                let newSession = try AugmentCookieImporter.importSession(logger: self.logger)

                self.log("✅ Session refresh successful - imported \(newSession.cookies.count) cookies from \(newSession.sourceLabel)")
                self.lastSuccessfulRefresh = Date()
            } else {
                self.log("⚠️ Session refresh returned no new cookies")
            }
        } catch {
            self.log("✗ Session refresh failed: \(error.localizedDescription)")
        }
    }

    /// Ping Augment's session endpoint to trigger cookie refresh
    private func pingSessionEndpoint() async throws -> Bool {
        // Try to get current cookies first
        let currentSession = try? AugmentCookieImporter.importSession(logger: self.logger)
        guard let cookieHeader = currentSession?.cookieHeader else {
            self.log("No cookies available for session ping")
            return false
        }

        // Ping the session endpoint (NextAuth/Auth0 pattern)
        let sessionURL = URL(string: "https://app.augmentcode.com/api/auth/session")!
        var request = URLRequest(url: sessionURL)
        request.timeoutInterval = self.refreshTimeout
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AugmentSessionKeepaliveError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            // Check if we got a valid session response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["user"] != nil || json["email"] != nil
            {
                self.log("Session endpoint returned valid session data")
                return true
            } else {
                self.log("Session endpoint returned 200 but no session data")
                return false
            }
        } else if httpResponse.statusCode == 401 {
            self.log("Session endpoint returned 401 - session expired")
            throw AugmentSessionKeepaliveError.sessionExpired
        } else {
            self.log("Session endpoint returned HTTP \(httpResponse.statusCode)")
            return false
        }
    }

    private func log(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        let fullMessage = "[\(timestamp)] [AugmentKeepalive] \(message)"
        self.logger?(fullMessage)
        print("[CodexBar] \(fullMessage)")
    }
}

// MARK: - Errors

public enum AugmentSessionKeepaliveError: LocalizedError, Sendable {
    case invalidResponse
    case sessionExpired
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from session endpoint"
        case .sessionExpired:
            "Session has expired"
        case let .networkError(message):
            "Network error: \(message)"
        }
    }
}

#endif
