import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import SweetCookieKit

// MARK: - Abacus Usage Fetcher

public enum AbacusUsageFetcher {
    private struct BrowserFetchRequest {
        let browserDetection: BrowserDetection
        let preferredBrowsers: [Browser]
        let label: String
        let timeout: TimeInterval
        let logger: ((String) -> Void)?
    }

    /// Parsed JSON dictionaries are treated as immutable snapshots here and are
    /// only moved between sibling fetch tasks before being consumed locally.
    private struct JSONDictionaryBox: @unchecked Sendable {
        let value: [String: Any]
    }

    private static let log = CodexBarLog.logger(LogCategories.abacusUsage)
    private static let computePointsURL =
        URL(string: "https://apps.abacus.ai/api/_getOrganizationComputePoints")!
    private static let billingInfoURL =
        URL(string: "https://apps.abacus.ai/api/_getBillingInfo")!

    public static func fetchUsage(
        cookieHeaderOverride: String? = nil,
        browserDetection: BrowserDetection = BrowserDetection(),
        timeout: TimeInterval = 15.0,
        logger: ((String) -> Void)? = nil) async throws -> AbacusUsageSnapshot
    {
        // Manual cookie header — no fallback, errors propagate directly
        if let override = CookieHeaderNormalizer.normalize(cookieHeaderOverride) {
            self.emit("Using manual cookie header", logger: logger)
            return try await self.fetchWithCookieHeader(override, timeout: timeout, logger: logger)
        }

        // Cached cookie header — fall back to a fresh browser import when the
        // cached session is rejected or looks stale.
        if let cached = CookieHeaderCache.load(provider: .abacus),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            self.emit("Using cached cookie header from \(cached.sourceLabel)", logger: logger)
            do {
                return try await self.fetchWithCookieHeader(
                    cached.cookieHeader, timeout: timeout, logger: logger)
            } catch let error as AbacusUsageError where error.shouldTryNextImportedSession {
                if error.shouldClearCachedCookie {
                    CookieHeaderCache.clear(provider: .abacus)
                    self.emit(
                        "Cached cookie failed (\(error.localizedDescription)); cleared, trying fresh import",
                        logger: logger)
                } else {
                    self.emit(
                        "Cached cookie failed (\(error.localizedDescription)); trying fresh import",
                        logger: logger)
                }
            }
        }

        // Fresh browser import — try Chrome first (AGENTS.md default), then broaden
        // to all browsers if Chrome has no sessions OR if every imported Chrome
        // session is exhausted without a successful fetch.
        var lastError: AbacusUsageError = .noSessionCookie
        if let snapshot = try await self.tryFetchFromBrowsers(
            BrowserFetchRequest(
                browserDetection: browserDetection,
                preferredBrowsers: [.chrome],
                label: "Chrome",
                timeout: timeout,
                logger: logger),
            lastError: &lastError)
        {
            return snapshot
        }

        self.emit("Chrome sessions exhausted; falling back to all browsers", logger: logger)
        if let snapshot = try await self.tryFetchFromBrowsers(
            BrowserFetchRequest(
                browserDetection: browserDetection,
                preferredBrowsers: [],
                label: "all browsers",
                timeout: timeout,
                logger: logger),
            lastError: &lastError)
        {
            return snapshot
        }

        throw lastError
    }

    /// Tries to import sessions from `preferredBrowsers` and fetch usage. Returns
    /// the snapshot on success, nil if no sessions were available or every
    /// imported session was exhausted without success.
    private static func tryFetchFromBrowsers(
        _ request: BrowserFetchRequest,
        lastError: inout AbacusUsageError) async throws -> AbacusUsageSnapshot?
    {
        let sessions: [AbacusCookieImporter.SessionInfo]
        do {
            sessions = try AbacusCookieImporter.importSessions(
                browserDetection: request.browserDetection,
                preferredBrowsers: request.preferredBrowsers,
                logger: request.logger)
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            self.emit(
                "\(request.label) cookie import failed: \(error.localizedDescription)",
                logger: request.logger)
            return nil
        }

        for session in sessions {
            self.emit("Trying cookies from \(session.sourceLabel)", logger: request.logger)
            do {
                let snapshot = try await self.fetchWithCookieHeader(
                    session.cookieHeader,
                    timeout: request.timeout,
                    logger: request.logger)
                CookieHeaderCache.store(
                    provider: .abacus,
                    cookieHeader: session.cookieHeader,
                    sourceLabel: session.sourceLabel)
                return snapshot
            } catch let error as AbacusUsageError where error.shouldTryNextImportedSession {
                self.emit(
                    "\(session.sourceLabel): \(error.localizedDescription), trying next source",
                    logger: request.logger)
                lastError = error
                continue
            } catch {
                self.emit(
                    "\(session.sourceLabel): \(error.localizedDescription), trying next source",
                    logger: request.logger)
                lastError = .networkError(error.localizedDescription)
                continue
            }
        }
        return nil
    }

    // MARK: - API Requests

    private static func fetchWithCookieHeader(
        _ cookieHeader: String,
        timeout: TimeInterval,
        logger: ((String) -> Void)? = nil) async throws -> AbacusUsageSnapshot
    {
        enum FetchPart: Sendable {
            case computePoints(JSONDictionaryBox)
            case billingInfoSuccess(JSONDictionaryBox)
            case billingInfoFailure(String)
        }

        // Fetch compute points (required, full timeout) and billing info
        // (optional, shorter budget) concurrently. Billing is bounded so a
        // slow/flaky billing endpoint can't delay credit rendering.
        let billingBudget = min(timeout, 5.0)

        var computePointsResult: [String: Any]?
        var billingInfoResult: [String: Any] = [:]

        try await withThrowingTaskGroup(of: FetchPart.self) { group in
            group.addTask {
                let result = try await self.fetchJSON(
                    url: self.computePointsURL,
                    method: "GET",
                    cookieHeader: cookieHeader,
                    timeout: timeout)
                return .computePoints(JSONDictionaryBox(value: result))
            }
            group.addTask {
                do {
                    let result = try await self.fetchJSON(
                        url: self.billingInfoURL,
                        method: "POST",
                        cookieHeader: cookieHeader,
                        timeout: billingBudget)
                    return .billingInfoSuccess(JSONDictionaryBox(value: result))
                } catch {
                    return .billingInfoFailure(error.localizedDescription)
                }
            }

            while let result = try await group.next() {
                switch result {
                case let .computePoints(value):
                    computePointsResult = value.value
                case let .billingInfoSuccess(value):
                    billingInfoResult = value.value
                case let .billingInfoFailure(message):
                    self.emit(
                        "Billing info fetch failed: \(message); credits shown without plan/reset",
                        logger: logger)
                }
            }
        }

        guard let computePointsResult else {
            throw AbacusUsageError.networkError("Abacus compute points fetch did not complete")
        }

        return try self.parseResults(computePoints: computePointsResult, billingInfo: billingInfoResult)
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
            request.httpBody = Data("{}".utf8)
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
                || errorMsg.contains("unauthorized") || errorMsg.contains("unauthenticated")
                || errorMsg.contains("forbidden")
            {
                throw AbacusUsageError.unauthorized
            }
            throw AbacusUsageError.parseFailed("\(url.lastPathComponent): \(errorMsg)")
        }

        return result
    }

    // MARK: - Parsing

    private static func parseResults(
        computePoints: [String: Any], billingInfo: [String: Any]) throws -> AbacusUsageSnapshot
    {
        let totalCredits = self.double(from: computePoints["totalComputePoints"])
        let creditsLeft = self.double(from: computePoints["computePointsLeft"])

        guard let totalCredits, let creditsLeft else {
            let keys = computePoints.keys.sorted().joined(separator: ", ")
            throw AbacusUsageError.parseFailed(
                "Missing credit fields in compute points response. Keys: [\(keys)]")
        }

        let creditsUsed = totalCredits - creditsLeft

        let nextBillingDate = billingInfo["nextBillingDate"] as? String
        let currentTier = billingInfo["currentTier"] as? String
        let resetsAt = self.parseDate(nextBillingDate)

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

    // MARK: - Logging

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
        browserDetection _: BrowserDetection = BrowserDetection(),
        timeout _: TimeInterval = 15.0,
        logger _: ((String) -> Void)? = nil) async throws -> AbacusUsageSnapshot
    {
        throw AbacusUsageError.notSupported
    }
}

#endif
