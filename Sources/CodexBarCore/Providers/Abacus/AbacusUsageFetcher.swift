import Foundation

#if os(macOS)
import SweetCookieKit

// MARK: - Abacus Usage Fetcher

public enum AbacusUsageFetcher {
    private static let log = CodexBarLog.logger(LogCategories.abacusUsage)
    private static let computePointsURL =
        URL(string: "https://apps.abacus.ai/api/_getOrganizationComputePoints")!
    private static let billingInfoURL =
        URL(string: "https://apps.abacus.ai/api/_getBillingInfo")!

    public static func fetchUsage(
        cookieHeaderOverride: String? = nil,
        timeout: TimeInterval = 15.0,
        logger: ((String) -> Void)? = nil) async throws -> AbacusUsageSnapshot
    {
        // Manual cookie header — no fallback, errors propagate directly
        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            self.emit("Using manual cookie header", logger: logger)
            return try await self.fetchWithCookieHeader(override, timeout: timeout, logger: logger)
        }

        // Cached cookie header — clear on recoverable errors and fall through
        if let cached = CookieHeaderCache.load(provider: .abacus),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            self.emit("Using cached cookie header from \(cached.sourceLabel)", logger: logger)
            do {
                return try await Self.fetchWithCookieHeader(
                    cached.cookieHeader, timeout: timeout, logger: logger)
            } catch let error as AbacusUsageError where error.isRecoverable {
                CookieHeaderCache.clear(provider: .abacus)
                self.emit(
                    "Cached cookie failed (\(error.localizedDescription)); cleared, trying fresh import",
                    logger: logger)
            }
        }

        // Fresh browser import — try each candidate, fall through on recoverable errors
        let sessions: [AbacusCookieImporter.SessionInfo]
        do {
            sessions = try AbacusCookieImporter.importSessions(logger: logger)
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            self.emit("Browser cookie import failed: \(error.localizedDescription)", logger: logger)
            throw AbacusUsageError.noSessionCookie
        }

        var lastError: AbacusUsageError = .noSessionCookie
        for session in sessions {
            self.emit("Trying cookies from \(session.sourceLabel)", logger: logger)
            do {
                let snapshot = try await Self.fetchWithCookieHeader(
                    session.cookieHeader, timeout: timeout, logger: logger)
                CookieHeaderCache.store(
                    provider: .abacus,
                    cookieHeader: session.cookieHeader,
                    sourceLabel: session.sourceLabel)
                return snapshot
            } catch let error as AbacusUsageError where error.isRecoverable {
                self.emit(
                    "\(session.sourceLabel): \(error.localizedDescription), trying next source",
                    logger: logger)
                lastError = error
                continue
            }
        }

        throw lastError
    }

    private static func fetchWithCookieHeader(
        _ cookieHeader: String,
        timeout: TimeInterval,
        logger: ((String) -> Void)? = nil) async throws -> AbacusUsageSnapshot
    {
        // Fetch compute points (GET) and billing info (POST) concurrently
        async let computePoints = Self.fetchJSON(
            url: self.computePointsURL, method: "GET", cookieHeader: cookieHeader, timeout: timeout)
        async let billingInfo = Self.fetchJSON(
            url: self.billingInfoURL, method: "POST", cookieHeader: cookieHeader, timeout: timeout)

        let cpResult = try await computePoints
        let biResult: [String: Any]
        do {
            biResult = try await billingInfo
        } catch let error as AbacusUsageError where error.isAuthRelated {
            throw error
        } catch {
            self.emit(
                "Billing info fetch failed: \(error.localizedDescription); credits shown without plan/reset",
                logger: logger)
            biResult = [:]
        }

        return try Self.parseResults(computePoints: cpResult, billingInfo: biResult)
    }

    private static func fetchJSON(
        url: URL, method: String, cookieHeader: String, timeout: TimeInterval) async throws -> [String: Any]
    {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if method == "POST" {
            request.httpBody = "{}".data(using: .utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AbacusUsageError.networkError("Invalid response from \(url.lastPathComponent)")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw AbacusUsageError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw AbacusUsageError.networkError("HTTP \(httpResponse.statusCode): \(body)")
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<non-UTF8>"
            throw AbacusUsageError.parseFailed(
                "\(url.lastPathComponent): \(error.localizedDescription) — preview: \(preview)")
        }

        guard let root = parsed as? [String: Any] else {
            throw AbacusUsageError.parseFailed("\(url.lastPathComponent): top-level JSON is not a dictionary")
        }

        guard root["success"] as? Bool == true,
              let result = root["result"] as? [String: Any]
        else {
            let errorMsg = (root["error"] as? String ?? "Unknown error").lowercased()
            if errorMsg.contains("expired") || errorMsg.contains("session")
                || errorMsg.contains("login") || errorMsg.contains("authenticate")
            {
                throw AbacusUsageError.sessionExpired
            }
            throw AbacusUsageError.parseFailed("\(url.lastPathComponent): \(errorMsg)")
        }

        return result
    }

    // MARK: - Parsing

    private static func parseResults(
        computePoints: [String: Any], billingInfo: [String: Any]) throws -> AbacusUsageSnapshot
    {
        let totalCredits = Self.double(from: computePoints["totalComputePoints"])
        let creditsLeft = Self.double(from: computePoints["computePointsLeft"])

        guard totalCredits != nil || creditsLeft != nil else {
            let keys = computePoints.keys.sorted().joined(separator: ", ")
            throw AbacusUsageError.parseFailed(
                "Missing credit fields in compute points response. Keys: [\(keys)]")
        }

        let creditsUsed: Double? = if let total = totalCredits, let left = creditsLeft {
            total - left
        } else {
            nil
        }

        let nextBillingDate = billingInfo["nextBillingDate"] as? String
        let currentTier = billingInfo["currentTier"] as? String
        let resetsAt = Self.parseDate(nextBillingDate)

        return AbacusUsageSnapshot(
            creditsUsed: creditsUsed,
            creditsTotal: totalCredits,
            resetsAt: resetsAt,
            planName: currentTier)
    }

    private static func double(from value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func parseDate(_ isoString: String?) -> Date? {
        guard let isoString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[abacus] \(message)")
        self.log.debug(message)
    }
}

#else

// MARK: - Abacus (Unsupported)

public enum AbacusUsageFetcher {
    public static func fetchUsage(
        cookieHeaderOverride _: String? = nil,
        timeout _: TimeInterval = 15.0,
        logger _: ((String) -> Void)? = nil) async throws -> AbacusUsageSnapshot
    {
        throw AbacusUsageError.notSupported
    }
}

#endif
