import Foundation

// MARK: - API Response Model

public struct WindsurfGetPlanStatusResponse: Codable, Sendable {
    public let planStatus: PlanStatus?

    public struct PlanStatus: Codable, Sendable {
        public let planInfo: PlanInfo?
        public let planStart: String?
        public let planEnd: String?
        public let availablePromptCredits: Int?
        public let availableFlowCredits: Int?
        public let dailyQuotaRemainingPercent: Double?
        public let weeklyQuotaRemainingPercent: Double?
        public let dailyQuotaResetAtUnix: String?
        public let weeklyQuotaResetAtUnix: String?
        public let topUpStatus: TopUpStatus?
        public let gracePeriodStatus: String?

        public struct PlanInfo: Codable, Sendable {
            public let planName: String?
            public let teamsTier: String?
        }

        public struct TopUpStatus: Codable, Sendable {
            public let topUpTransactionStatus: String?
        }
    }
}

// MARK: - Conversion to UsageSnapshot

extension WindsurfGetPlanStatusResponse {
    public func toUsageSnapshot() -> UsageSnapshot {
        var primary: RateWindow?
        var secondary: RateWindow?

        if let status = self.planStatus {
            if let daily = status.dailyQuotaRemainingPercent {
                let resetDate = status.dailyQuotaResetAtUnix.flatMap { Int64($0) }.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                primary = RateWindow(
                    usedPercent: max(0, min(100, 100 - daily)),
                    windowMinutes: nil,
                    resetsAt: resetDate,
                    resetDescription: Self.formatResetDescription(resetDate))
            }

            if let weekly = status.weeklyQuotaRemainingPercent {
                let resetDate = status.weeklyQuotaResetAtUnix.flatMap { Int64($0) }.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                secondary = RateWindow(
                    usedPercent: max(0, min(100, 100 - weekly)),
                    windowMinutes: nil,
                    resetsAt: resetDate,
                    resetDescription: Self.formatResetDescription(resetDate))
            }
        }

        var orgDescription: String?
        if let planEnd = self.planStatus?.planEnd {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let endDate = isoFormatter.date(from: planEnd)
                ?? ISO8601DateFormatter().date(from: planEnd)
            if let endDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                orgDescription = "Expires \(formatter.string(from: endDate))"
            }
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .windsurf,
            accountEmail: nil,
            accountOrganization: orgDescription,
            loginMethod: self.planStatus?.planInfo?.planName)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: Date(),
            identity: identity)
    }

    private static func formatResetDescription(_ date: Date?) -> String? {
        guard let date else { return nil }
        let now = Date()
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Expired" }

        let hours = Int(interval / 3600)
        let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "Resets in \(days)d \(remainingHours)h"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }
}

// MARK: - Web Fetcher

#if os(macOS)

public enum WindsurfWebFetcherError: LocalizedError, Sendable {
    case noFirebaseToken
    case tokenRefreshFailed(String)
    case apiCallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noFirebaseToken:
            "No Firebase token found in browser IndexedDB. Sign in to windsurf.com in Chrome or Edge first."
        case let .tokenRefreshFailed(message):
            "Firebase token refresh failed: \(message)"
        case let .apiCallFailed(message):
            "Windsurf API call failed: \(message)"
        }
    }
}

public enum WindsurfWebFetcher {
    // Public Firebase API key (embedded in windsurf.com frontend)
    private static let firebaseAPIKey = "AIzaSyDsOl-1XpT5err0Tcnx8FFod1H8gVGIycY"
    private static let windsurfOrigin = "https://windsurf.com"
    private static let windsurfUsageReferer = "https://windsurf.com/subscription/usage"
    private static let getPlanStatusURL = "https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus"

    public static func fetchUsage(
        browserDetection: BrowserDetection,
        cookieSource: ProviderCookieSource = .auto,
        manualAccessToken: String? = nil,
        timeout: TimeInterval = 15,
        logger: ((String) -> Void)? = nil,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[windsurf-web] \(msg)") }
        let useKeychain = cookieSource == .auto

        // 0. Manual token override (cookie source = manual)
        // Accepts either a refresh token (AMf-vB prefix, long-lived) or access token (eyJ prefix, ~1h)
        if let manualAccessToken, !manualAccessToken.isEmpty {
            let token = manualAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("AMf-vB") {
                log("Using manual refresh token → exchanging for access token")
                let accessToken = try await self.refreshFirebaseToken(token, timeout: timeout, session: session)
                let response = try await self.fetchPlanStatus(
                    accessToken: accessToken,
                    timeout: timeout,
                    session: session)
                return response.toUsageSnapshot()
            } else {
                log("Using manual access token")
                let response = try await self.fetchPlanStatus(accessToken: token, timeout: timeout, session: session)
                return response.toUsageSnapshot()
            }
        }

        // 1. Try cached token from CookieHeaderCache (only when auto / Keychain allowed)
        if useKeychain, let cached = CookieHeaderCache.load(provider: .windsurf) {
            log("Trying cached Firebase access token")
            do {
                let response = try await self.fetchPlanStatus(
                    accessToken: cached.cookieHeader,
                    timeout: timeout,
                    session: session)
                return response.toUsageSnapshot()
            } catch {
                log("Cached token failed: \(error.localizedDescription)")
                CookieHeaderCache.clear(provider: .windsurf)
            }
        }

        // 2. Import Firebase tokens from browser IndexedDB
        let tokenInfos = WindsurfFirebaseTokenImporter.importFirebaseTokens(
            browserDetection: browserDetection,
            logger: logger)
        guard !tokenInfos.isEmpty else {
            throw WindsurfWebFetcherError.noFirebaseToken
        }

        var lastError: Error?

        for tokenInfo in tokenInfos {
            // 2a. Try existing access token first (if not expired)
            if let accessToken = tokenInfo.accessToken {
                log("Trying access token from \(tokenInfo.sourceLabel)")
                do {
                    let response = try await self.fetchPlanStatus(
                        accessToken: accessToken,
                        timeout: timeout,
                        session: session)
                    if useKeychain {
                        CookieHeaderCache.store(
                            provider: .windsurf,
                            cookieHeader: accessToken,
                            sourceLabel: tokenInfo.sourceLabel)
                    }
                    return response.toUsageSnapshot()
                } catch {
                    log("Access token failed: \(error.localizedDescription)")
                    lastError = error
                }
            }

            // 2b. Refresh token to get new access token
            log("Refreshing Firebase token from \(tokenInfo.sourceLabel)")
            do {
                let accessToken = try await self.refreshFirebaseToken(
                    tokenInfo.refreshToken,
                    timeout: timeout,
                    session: session)
                let response = try await self.fetchPlanStatus(
                    accessToken: accessToken,
                    timeout: timeout,
                    session: session)
                if useKeychain {
                    CookieHeaderCache.store(
                        provider: .windsurf,
                        cookieHeader: accessToken,
                        sourceLabel: tokenInfo.sourceLabel)
                }
                return response.toUsageSnapshot()
            } catch {
                log("Token refresh/API call failed: \(error.localizedDescription)")
                lastError = error
            }
        }

        throw lastError ?? WindsurfWebFetcherError.noFirebaseToken
    }

    // MARK: - Firebase Token Refresh

    private static func refreshFirebaseToken(
        _ refreshToken: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> String
    {
        guard let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(self.firebaseAPIKey)") else {
            throw WindsurfWebFetcherError.tokenRefreshFailed("Invalid Firebase token URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        self.applyWindsurfHeaders(to: &request)

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw WindsurfWebFetcherError.tokenRefreshFailed("Invalid refresh token request body")
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WindsurfWebFetcherError.tokenRefreshFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<binary>"
            let snippet = body.isEmpty ? "" : ": \(body.prefix(200))"
            throw WindsurfWebFetcherError.tokenRefreshFailed("HTTP \(httpResponse.statusCode)\(snippet)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw WindsurfWebFetcherError.tokenRefreshFailed("Missing access_token in response")
        }

        return accessToken
    }

    // MARK: - GetPlanStatus API

    private static func fetchPlanStatus(
        accessToken: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> WindsurfGetPlanStatusResponse
    {
        guard let url = URL(string: self.getPlanStatusURL) else {
            throw WindsurfWebFetcherError.apiCallFailed("Invalid GetPlanStatus URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        self.applyWindsurfHeaders(to: &request)

        let body: [String: Any] = [
            "authToken": accessToken,
            "includeTopUpStatus": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WindsurfWebFetcherError.apiCallFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<binary>"
            let snippet = body.isEmpty ? "" : ": \(body.prefix(200))"
            throw WindsurfWebFetcherError.apiCallFailed("HTTP \(httpResponse.statusCode)\(snippet)")
        }

        do {
            return try JSONDecoder().decode(WindsurfGetPlanStatusResponse.self, from: data)
        } catch {
            throw WindsurfWebFetcherError.apiCallFailed("Parse error: \(error.localizedDescription)")
        }
    }

    private static func applyWindsurfHeaders(to request: inout URLRequest) {
        request.setValue(self.windsurfOrigin, forHTTPHeaderField: "Origin")
        request.setValue(self.windsurfUsageReferer, forHTTPHeaderField: "Referer")
    }
}

#endif
