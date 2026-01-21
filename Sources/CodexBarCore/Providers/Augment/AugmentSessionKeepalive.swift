import Foundation

#if os(macOS)
import AppKit
import UserNotifications

/// Manages automatic session keepalive for Augment to prevent cookie expiration.
///
/// This actor monitors cookie expiration and proactively refreshes the session
/// before cookies expire, ensuring uninterrupted access to Augment APIs.
@MainActor
public final class AugmentSessionKeepalive {
    // MARK: - Configuration

    /// How often to check if session needs refresh (default: 1 minute for faster recovery)
    private let checkInterval: TimeInterval = 60

    /// Refresh session this many seconds before cookie expiration (default: 5 minutes)
    private let refreshBufferSeconds: TimeInterval = 300

    /// Minimum time between refresh attempts (default: 1 minute for faster recovery)
    private let minRefreshInterval: TimeInterval = 60

    /// Maximum time to wait for session refresh (default: 30 seconds)
    private let refreshTimeout: TimeInterval = 30

    // MARK: - State

    private var timerTask: Task<Void, Never>?
    private var lastRefreshAttempt: Date?
    private var lastSuccessfulRefresh: Date?
    private var isRefreshing = false
    private let logger: ((String) -> Void)?
    private var onSessionRecovered: (() async -> Void)?

    /// Track consecutive failures to stop retrying after too many failures
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3 // Stop after 3 failures
    private var hasGivenUp = false

    // MARK: - Initialization

    public init(logger: ((String) -> Void)? = nil, onSessionRecovered: (() async -> Void)? = nil) {
        self.logger = logger
        self.onSessionRecovered = onSessionRecovered
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

        // Stop trying if we've given up
        if self.hasGivenUp {
            self.log("⏸️ Keepalive has given up after \(self.maxConsecutiveFailures) consecutive failures")
            self.log("   User must manually log in to Augment and click 'Refresh Session'")
            return
        }

        // Rate limit: don't refresh too frequently
        if let lastAttempt = self.lastRefreshAttempt {
            let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
            if timeSinceLastAttempt < self.minRefreshInterval {
                self.log(
                    "Skipping refresh (last attempt \(Int(timeSinceLastAttempt))s ago, " +
                        "min interval: \(Int(self.minRefreshInterval))s)")
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

            self.log("📊 Cookie Status Check:")
            self.log("   Total cookies: \(session.cookies.count)")
            self.log("   Source: \(session.sourceLabel)")

            // Log each cookie's expiration status
            for cookie in session.cookies {
                if let expiry = cookie.expiresDate {
                    let timeUntil = expiry.timeIntervalSinceNow
                    let status = timeUntil > 0 ? "expires in \(Int(timeUntil))s" : "EXPIRED \(Int(-timeUntil))s ago"
                    self.log("   - \(cookie.name): \(status)")
                } else {
                    self.log("   - \(cookie.name): session cookie (no expiry)")
                }
            }

            // Find the earliest expiration date among session cookies
            let expirationDates = session.cookies.compactMap(\.expiresDate)

            guard !expirationDates.isEmpty else {
                // Session cookies (no expiration) - refresh periodically
                self.log("   All cookies are session cookies (no expiration dates)")
                if let lastRefresh = self.lastSuccessfulRefresh {
                    let timeSinceRefresh = Date().timeIntervalSince(lastRefresh)
                    // Refresh every 30 minutes for session cookies
                    if timeSinceRefresh > 1800 {
                        self.log("   ⚠️ Need periodic refresh (\(Int(timeSinceRefresh))s since last refresh)")
                        return true
                    } else {
                        self.log("   ✅ Recently refreshed (\(Int(timeSinceRefresh))s ago)")
                        return false
                    }
                } else {
                    // Never refreshed - do it now
                    self.log("   ⚠️ Never refreshed - doing initial refresh")
                    return true
                }
            }

            let earliestExpiration = expirationDates.min()!
            let timeUntilExpiration = earliestExpiration.timeIntervalSinceNow
            let expiringCookie = session.cookies.first { $0.expiresDate == earliestExpiration }

            if timeUntilExpiration < self.refreshBufferSeconds {
                self.log("   ⚠️ REFRESH NEEDED:")
                self.log("      Earliest expiring cookie: \(expiringCookie?.name ?? "unknown")")
                self.log("      Time until expiration: \(Int(timeUntilExpiration))s")
                self.log("      Refresh threshold: \(Int(self.refreshBufferSeconds))s")
                return true
            } else {
                self.log("   ✅ Session healthy:")
                self.log("      Earliest expiring cookie: \(expiringCookie?.name ?? "unknown")")
                self.log("      Time until expiration: \(Int(timeUntilExpiration))s")
                return false
            }
        } catch {
            self.log("✗ Failed to check session: \(error.localizedDescription)")
            return false
        }
    }

    private func performRefresh(forced: Bool) async {
        self.isRefreshing = true
        self.lastRefreshAttempt = Date()
        defer { self.isRefreshing = false }

        self.log(forced ? "Performing forced session refresh..." : "Performing automatic session refresh...")

        // If this is a forced refresh (user clicked "Refresh Session"), reset failure tracking
        if forced {
            self.consecutiveFailures = 0
            self.hasGivenUp = false
            self.log("🔄 Manual refresh - resetting failure tracking")
        }

        do {
            // Step 1: Ping the session endpoint to trigger cookie refresh
            let refreshed = try await self.pingSessionEndpoint()

            if refreshed {
                // Step 2: Re-import cookies from browser
                try await Task.sleep(for: .seconds(1)) // Brief delay for browser to update cookies
                let newSession = try AugmentCookieImporter.importSession(logger: self.logger)

                self.log(
                    "✅ Session refresh successful - imported \(newSession.cookies.count) cookies " +
                        "from \(newSession.sourceLabel)")
                self.lastSuccessfulRefresh = Date()

                // Reset failure tracking on success
                self.consecutiveFailures = 0
                self.hasGivenUp = false
            } else {
                self.log("⚠️ Session refresh returned no new cookies")
                self.consecutiveFailures += 1
                self.checkIfShouldGiveUp()
            }
        } catch AugmentSessionKeepaliveError.sessionExpired {
            self.log("🔐 Session expired - attempting automatic recovery...")
            self.consecutiveFailures += 1

            if self.consecutiveFailures >= self.maxConsecutiveFailures {
                self.log("❌ Too many consecutive failures (\(self.consecutiveFailures)) - giving up")
                self.log("   User must manually log in to Augment and click 'Refresh Session'")
                self.hasGivenUp = true
                self.notifyUserLoginRequired()
            } else {
                await self.attemptSessionRecovery()
            }
        } catch {
            self.log("✗ Session refresh failed: \(error.localizedDescription)")
            self.consecutiveFailures += 1
            self.checkIfShouldGiveUp()
        }
    }

    private func checkIfShouldGiveUp() {
        if self.consecutiveFailures >= self.maxConsecutiveFailures {
            self.log("❌ Too many consecutive failures (\(self.consecutiveFailures)) - giving up")
            self.log("   User must manually log in to Augment and click 'Refresh Session'")
            self.hasGivenUp = true
            self.notifyUserLoginRequired()
        }
    }

    /// Attempt to recover from an expired session by triggering browser re-authentication
    private func attemptSessionRecovery() async {
        self.log("🔄 Attempting automatic session recovery...")
        self.log("   Strategy: Open Augment dashboard to trigger browser re-auth")

        #if os(macOS)
        // Open the Augment dashboard in the default browser
        // This will trigger the browser to re-authenticate if the user is still logged in
        if let url = URL(string: "https://app.augmentcode.com") {
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            self.log("   ✅ Opened Augment dashboard in browser")
            self.log("   ⏳ Waiting 5 seconds for browser to re-authenticate...")

            // Wait for browser to potentially re-authenticate
            try? await Task.sleep(for: .seconds(5))

            // Try to import cookies again
            do {
                let newSession = try AugmentCookieImporter.importSession(logger: self.logger)
                self.log("   ✅ Session recovery successful - imported \(newSession.cookies.count) cookies")
                self.lastSuccessfulRefresh = Date()

                // Verify the session is actually valid by pinging the API
                let isValid = try await self.pingSessionEndpoint()
                if isValid {
                    self.log("   ✅ Session verified - recovery complete!")
                    // Notify UsageStore to refresh Augment usage
                    if let callback = self.onSessionRecovered {
                        self.log("   🔄 Triggering usage refresh after successful recovery")
                        await callback()
                    }
                } else {
                    self.log("   ⚠️ Session imported but not yet valid - may need manual login")
                    self.notifyUserLoginRequired()
                }
            } catch {
                self.log("   ✗ Session recovery failed: \(error.localizedDescription)")
                self.log("   ℹ️ User needs to manually log in to Augment")
                self.notifyUserLoginRequired()
            }
        }
        #else
        self.log("   ✗ Automatic recovery not supported on this platform")
        #endif
    }

    /// Notify the user that they need to log in to Augment
    private func notifyUserLoginRequired() {
        #if os(macOS)
        self.log("📢 Sending notification: Augment session expired")

        Task {
            let center = UNUserNotificationCenter.current()

            // Request authorization if needed
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    self.log("⚠️ Notification permission denied")
                    return
                }
            } catch {
                self.log("✗ Failed to request notification permission: \(error)")
                return
            }

            // Create notification content
            let content = UNMutableNotificationContent()
            content.title = "Augment Session Expired"
            content.body = "Please log in to app.augmentcode.com to restore your session."
            content.sound = .default

            // Create trigger (deliver immediately)
            let request = UNNotificationRequest(
                identifier: "augment-session-expired-\(UUID().uuidString)",
                content: content,
                trigger: nil)

            // Deliver notification
            do {
                try await center.add(request)
                self.log("✅ Notification delivered successfully")
            } catch {
                self.log("✗ Failed to deliver notification: \(error)")
            }
        }
        #endif
    }

    /// Ping Augment's session endpoint to trigger cookie refresh
    private func pingSessionEndpoint() async throws -> Bool {
        // Try to get current cookies first
        let currentSession = try? AugmentCookieImporter.importSession(logger: self.logger)
        guard let cookieHeader = currentSession?.cookieHeader else {
            self.log("No cookies available for session ping")
            return false
        }

        self.log("🔄 Attempting session refresh...")
        self.log("   Cookies being sent: \(cookieHeader.prefix(100))...")

        // Try multiple endpoints - Augment might use different auth patterns
        let endpoints = [
            "https://app.augmentcode.com/api/auth/session", // NextAuth pattern
            "https://app.augmentcode.com/api/session", // Alternative
            "https://app.augmentcode.com/api/user", // User endpoint
        ]

        var receivedUnauthorized = false

        for (index, urlString) in endpoints.enumerated() {
            self.log("   Trying endpoint \(index + 1)/\(endpoints.count): \(urlString)")

            guard let sessionURL = URL(string: urlString) else { continue }
            var request = URLRequest(url: sessionURL)
            request.timeoutInterval = self.refreshTimeout
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://app.augmentcode.com", forHTTPHeaderField: "Origin")
            request.setValue("https://app.augmentcode.com", forHTTPHeaderField: "Referer")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.log("   ✗ Invalid response type")
                    continue
                }

                self.log("   Response: HTTP \(httpResponse.statusCode)")

                // Log Set-Cookie headers if present
                if let setCookies = httpResponse.allHeaderFields["Set-Cookie"] as? String {
                    self.log("   Set-Cookie headers received: \(setCookies.prefix(100))...")
                }

                if httpResponse.statusCode == 200 {
                    // Check if we got a valid session response
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.log("   JSON response keys: \(json.keys.joined(separator: ", "))")

                        if json["user"] != nil || json["email"] != nil || json["session"] != nil {
                            self.log("   ✅ Valid session data found!")
                            return true
                        } else {
                            self.log("   ⚠️ 200 OK but no session data in response")
                            // Try next endpoint
                            continue
                        }
                    } else {
                        self.log("   ⚠️ 200 OK but response is not JSON")
                        if let responseText = String(data: data, encoding: .utf8) {
                            self.log("   Response text: \(responseText.prefix(200))...")
                        }
                        continue
                    }
                } else if httpResponse.statusCode == 401 {
                    self.log("   ✗ 401 Unauthorized - session expired")
                    receivedUnauthorized = true
                    // Don't throw immediately - try all endpoints first
                    continue
                } else if httpResponse.statusCode == 404 {
                    self.log("   ✗ 404 Not Found - trying next endpoint")
                    continue
                } else {
                    self.log("   ✗ HTTP \(httpResponse.statusCode) - trying next endpoint")
                    continue
                }
            } catch {
                self.log("   ✗ Request failed: \(error.localizedDescription)")
                continue
            }
        }

        // If we got 401 from all endpoints, the session is definitely expired
        if receivedUnauthorized {
            self.log("⚠️ All endpoints returned 401 - session is expired")
            throw AugmentSessionKeepaliveError.sessionExpired
        }

        self.log("⚠️ All session endpoints failed or returned no valid data")
        return false
    }

    private static let log = CodexBarLog.logger(LogCategories.augmentKeepalive)

    private func log(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        let fullMessage = "[\(timestamp)] [AugmentKeepalive] \(message)"
        self.logger?(fullMessage)
        Self.log.debug(fullMessage)
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
