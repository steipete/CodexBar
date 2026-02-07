import Foundation

#if os(macOS)
import AppKit
import UserNotifications

/// Manages automatic session keepalive for CodeBuddy to prevent cookie expiration.
///
/// This class monitors cookie expiration and proactively refreshes the session
/// before cookies expire, ensuring uninterrupted access to CodeBuddy APIs.
@MainActor
public final class CodeBuddySessionKeepalive {
    // MARK: - Configuration

    /// How often to check if session needs refresh (default: 2 minutes)
    private let checkInterval: TimeInterval = 120

    /// Refresh session this many seconds before cookie expiration (default: 10 minutes)
    private let refreshBufferSeconds: TimeInterval = 600

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
    private var onSessionRecovered: (() async -> Void)?

    /// Track consecutive failures to stop retrying after too many failures
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3
    private var hasGivenUp = false

    private static let log = CodexBarLog.logger(LogCategories.codeBuddyKeepalive)

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

        self.log("Starting CodeBuddy session keepalive")
        self.log("   - Check interval: \(Int(self.checkInterval))s")
        self.log("   - Refresh buffer: \(Int(self.refreshBufferSeconds))s before expiry")
        self.log("   - Min refresh interval: \(Int(self.minRefreshInterval))s")

        self.timerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.checkInterval ?? 120))
                await self?.checkAndRefreshIfNeeded()
            }
        }

        self.log("Keepalive timer started successfully")
    }

    /// Stop the automatic session keepalive timer
    public func stop() {
        self.log("Stopping CodeBuddy session keepalive")
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
            self.log("Keepalive has given up after \(self.maxConsecutiveFailures) consecutive failures")
            return
        }

        // Rate limit: don't refresh too frequently
        if let lastAttempt = self.lastRefreshAttempt {
            let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
            if timeSinceLastAttempt < self.minRefreshInterval {
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
            let session = try CodeBuddyCookieImporter.importSession()

            self.log("Cookie Status Check:")
            self.log("   Total cookies: \(session.cookies.count)")
            self.log("   Source: \(session.sourceLabel)")

            // Find the earliest expiration date among session cookies
            let expirationDates = session.cookies.compactMap(\.expiresDate)

            guard !expirationDates.isEmpty else {
                // Session cookies (no expiration) - refresh periodically
                self.log("   All cookies are session cookies (no expiration dates)")
                if let lastRefresh = self.lastSuccessfulRefresh {
                    let timeSinceRefresh = Date().timeIntervalSince(lastRefresh)
                    // Refresh every 20 minutes for session cookies
                    if timeSinceRefresh > 1200 {
                        self.log("   Need periodic refresh (\(Int(timeSinceRefresh))s since last refresh)")
                        return true
                    } else {
                        self.log("   Recently refreshed (\(Int(timeSinceRefresh))s ago)")
                        return false
                    }
                } else {
                    // Never refreshed - do it now
                    self.log("   Never refreshed - doing initial refresh")
                    return true
                }
            }

            let earliestExpiration = expirationDates.min()!
            let timeUntilExpiration = earliestExpiration.timeIntervalSinceNow

            if timeUntilExpiration < self.refreshBufferSeconds {
                self.log("   REFRESH NEEDED: expires in \(Int(timeUntilExpiration))s")
                return true
            } else {
                self.log("   Session healthy: expires in \(Int(timeUntilExpiration))s")
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

        // If this is a forced refresh, reset failure tracking
        if forced {
            self.consecutiveFailures = 0
            self.hasGivenUp = false
        }

        do {
            // Step 1: Ping the session endpoint to trigger cookie refresh
            let refreshed = try await self.pingSessionEndpoint()

            if refreshed {
                // Step 2: Re-import cookies from browser
                try await Task.sleep(for: .seconds(1))
                let newSession = try CodeBuddyCookieImporter.importSession()

                self.log("Session refresh successful - imported \(newSession.cookies.count) cookies")
                self.lastSuccessfulRefresh = Date()
                self.consecutiveFailures = 0
                self.hasGivenUp = false

                // Notify callback
                if let callback = self.onSessionRecovered {
                    await callback()
                }
            } else {
                self.log("Session refresh returned no new cookies")
                self.consecutiveFailures += 1
                self.checkIfShouldGiveUp()
            }
        } catch CodeBuddySessionKeepaliveError.sessionExpired {
            self.log("Session expired - attempting automatic recovery...")
            self.consecutiveFailures += 1

            if self.consecutiveFailures >= self.maxConsecutiveFailures {
                self.log("Too many consecutive failures - giving up")
                self.hasGivenUp = true
                self.notifyUserLoginRequired()
            } else {
                await self.attemptSessionRecovery()
            }
        } catch {
            self.log("Session refresh failed: \(error.localizedDescription)")
            self.consecutiveFailures += 1
            self.checkIfShouldGiveUp()
        }
    }

    private func checkIfShouldGiveUp() {
        if self.consecutiveFailures >= self.maxConsecutiveFailures {
            self.log("Too many consecutive failures - giving up")
            self.hasGivenUp = true
            self.notifyUserLoginRequired()
        }
    }

    /// Attempt to recover from an expired session by opening the dashboard
    private func attemptSessionRecovery() async {
        self.log("Attempting automatic session recovery...")

        #if os(macOS)
        // Open the CodeBuddy dashboard in the default browser
        if let url = URL(string: "https://tencent.sso.codebuddy.cn/profile/usage") {
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            self.log("Opened CodeBuddy dashboard in browser")

            // Wait for browser to potentially re-authenticate
            try? await Task.sleep(for: .seconds(5))

            // Try to import cookies again
            do {
                let newSession = try CodeBuddyCookieImporter.importSession()
                self.log("Session recovery successful - imported \(newSession.cookies.count) cookies")
                self.lastSuccessfulRefresh = Date()

                // Verify the session is actually valid
                let isValid = try await self.pingSessionEndpoint()
                if isValid {
                    self.log("Session verified - recovery complete!")
                    if let callback = self.onSessionRecovered {
                        await callback()
                    }
                } else {
                    self.log("Session imported but not yet valid - may need manual login")
                    self.notifyUserLoginRequired()
                }
            } catch {
                self.log("Session recovery failed: \(error.localizedDescription)")
                self.notifyUserLoginRequired()
            }
        }
        #endif
    }

    /// Notify the user that they need to log in to CodeBuddy
    private func notifyUserLoginRequired() {
        #if os(macOS)
        self.log("Sending notification: CodeBuddy session expired")

        Task {
            let center = UNUserNotificationCenter.current()

            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    self.log("Notification permission denied")
                    return
                }
            } catch {
                self.log("Failed to request notification permission: \(error)")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "CodeBuddy Session Expired"
            content.body = "Please log in to tencent.sso.codebuddy.cn to restore your session."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "codebuddy-session-expired-\(UUID().uuidString)",
                content: content,
                trigger: nil)

            do {
                try await center.add(request)
                self.log("Notification delivered successfully")
            } catch {
                self.log("Failed to deliver notification: \(error)")
            }
        }
        #endif
    }

    /// Ping CodeBuddy's API endpoint to check session validity
    private func pingSessionEndpoint() async throws -> Bool {
        let currentSession = try? CodeBuddyCookieImporter.importSession()
        guard let cookieHeader = currentSession?.cookieHeader else {
            self.log("No cookies available for session ping")
            return false
        }

        // We need enterprise ID to make a valid API call
        // Try to get it from environment or use a simple endpoint
        let profileURL = URL(string: "https://tencent.sso.codebuddy.cn/profile/usage")!

        var request = URLRequest(url: profileURL)
        request.timeoutInterval = self.refreshTimeout
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("https://tencent.sso.codebuddy.cn", forHTTPHeaderField: "Origin")
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                self.log("Invalid response type")
                return false
            }

            self.log("Session ping response: HTTP \(httpResponse.statusCode)")

            if httpResponse.statusCode == 200 {
                self.log("Session is valid")
                return true
            } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 302 {
                // 302 redirect to login page also means session expired
                self.log("Session expired (HTTP \(httpResponse.statusCode))")
                throw CodeBuddySessionKeepaliveError.sessionExpired
            } else {
                self.log("Unexpected response: HTTP \(httpResponse.statusCode)")
                return false
            }
        } catch let error as CodeBuddySessionKeepaliveError {
            throw error
        } catch {
            self.log("Request failed: \(error.localizedDescription)")
            return false
        }
    }

    private func log(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        let fullMessage = "[\(timestamp)] [CodeBuddyKeepalive] \(message)"
        self.logger?(fullMessage)
        Self.log.debug(fullMessage)
    }
}

// MARK: - Errors

public enum CodeBuddySessionKeepaliveError: LocalizedError, Sendable {
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
