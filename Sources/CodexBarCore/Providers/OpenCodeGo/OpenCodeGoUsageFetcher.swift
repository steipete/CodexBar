import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OpenCodeGoUsageError: LocalizedError {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)
    case noSubscription

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "OpenCode Go credentials are invalid or expired."
        case let .networkError(message):
            "OpenCode Go network error: \(message)"
        case let .apiError(message):
            "OpenCode Go API error: \(message)"
        case let .parseFailed(message):
            "OpenCode Go parse error: \(message)"
        case .noSubscription:
            "No OpenCode Go subscription or supported prepaid balance is available."
        }
    }
}

public struct OpenCodeGoUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.opencodego, scope: "usage"))
    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let authURL = URL(string: "https://opencode.ai/auth")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let usageAPIURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let billingServerID = "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d"
    /// Cookie-authenticated Console workspace list, fetched without a workspace header.
    static let consoleWorkspacesURL = URL(string: "https://opencode.ai/console/api/orgs")!
    /// Go subscription meters for the workspace named by `consoleWorkspaceHeaderField`.
    static let consoleGoStatusURL = URL(string: "https://opencode.ai/console/api/go/status")!
    /// Prepaid balance for the selected Console workspace.
    static let consoleBillingStatusURL = URL(string: "https://opencode.ai/console/api/billing/status")!
    /// The console answers HTTP 400 when this header is missing.
    static let consoleWorkspaceHeaderField = "x-org-id"

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void)
        {
            guard OpenCodeGoUsageFetcher.allowsRedirect(
                from: task.originalRequest?.url,
                to: request.url)
            else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    private struct ServerRequest {
        let serverID: String
        let args: String?
        let method: String
        let referer: URL
    }

    // swiftformat:disable:next redundantSendable
    struct ZenBalanceRequest: Sendable {
        let workspaceID: String
        let cookieHeader: String
        let timeout: TimeInterval
        let session: URLSession
    }

    private static let redirectGuardDelegate = RedirectGuardDelegate()
    private static let redirectGuardSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        return URLSession(
            configuration: configuration,
            delegate: OpenCodeGoUsageFetcher.redirectGuardDelegate,
            delegateQueue: nil)
    }()

    public static func fetchUsage(
        cookieHeader: String,
        timeout: TimeInterval,
        now: Date = Date(),
        workspaceIDOverride: String? = nil,
        includeZenBalance: Bool = true,
        waitForZenBalance: Bool = false,
        session: URLSession? = nil) async throws -> OpenCodeGoUsageSnapshot
    {
        let session = session ?? self.redirectGuardSession
        guard let requestCookieHeader = OpenCodeWebCookieSupport.requestCookieHeader(from: cookieHeader) else {
            throw OpenCodeGoUsageError.invalidCredentials
        }
        let workspaceID: String = if let override = self.normalizeWorkspaceID(workspaceIDOverride) {
            override
        } else {
            try await self.fetchWorkspaceID(
                cookieHeader: requestCookieHeader,
                timeout: timeout,
                session: session)
        }
        let zenBalanceRequest = ZenBalanceRequest(
            workspaceID: workspaceID,
            cookieHeader: requestCookieHeader,
            timeout: timeout,
            session: session)
        let subscriptionTask = Task {
            try await self.fetchSubscriptionPayload(
                workspaceID: workspaceID,
                cookieHeader: requestCookieHeader,
                timeout: timeout,
                session: session)
        }
        let zenBalanceStart = ContinuousClock.now
        let zenBalanceTask = includeZenBalance ? Task {
            try await Task.sleep(for: self.optionalZenBalanceStartDelay)
            return try await self.fetchZenBalance(
                workspaceID: workspaceID,
                cookieHeader: requestCookieHeader,
                timeout: timeout,
                session: session)
        } : nil
        defer {
            subscriptionTask.cancel()
            zenBalanceTask?.cancel()
        }
        let subscriptionText: String
        do {
            subscriptionText = try await withTaskCancellationHandler {
                try await subscriptionTask.value
            } onCancel: {
                subscriptionTask.cancel()
                zenBalanceTask?.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OpenCodeGoUsageError {
            return try await self.requiredZenBalanceFallback(
                from: zenBalanceTask,
                for: error,
                request: zenBalanceRequest,
                now: now)
        } catch {
            throw error
        }
        let snapshot: OpenCodeGoUsageSnapshot
        do {
            snapshot = try self.parseSubscription(text: subscriptionText, now: now)
        } catch let error as OpenCodeGoUsageError {
            return try await self.requiredZenBalanceFallback(
                from: zenBalanceTask,
                for: error,
                request: zenBalanceRequest,
                now: now)
        }
        guard let zenBalanceTask else {
            return snapshot
        }
        let zenBalance = try await self.completedOptionalZenBalance(
            from: zenBalanceTask,
            timeout: self.optionalZenBalanceJoinTimeout(
                since: zenBalanceStart,
                waitForZenBalance: waitForZenBalance))
        return snapshot.withZenBalanceUSD(zenBalance)
    }

    public static func fetchAPIUsage(
        apiKey: String,
        timeout: TimeInterval,
        now: Date = Date(),
        session: URLSession? = nil) async throws -> OpenCodeGoUsageSnapshot
    {
        let token = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw OpenCodeGoSettingsError.missingAPIKey
        }

        var request = URLRequest(url: self.usageAPIURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")

        let response = try await (session ?? self.redirectGuardSession).response(for: request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw OpenCodeGoUsageError.invalidCredentials
            }
            let body = String(data: response.data, encoding: .utf8) ?? ""
            if let message = OpenCodeWebParsing.extractServerErrorMessage(from: body) {
                throw OpenCodeGoUsageError.apiError("HTTP \(response.statusCode): \(message)")
            }
            throw OpenCodeGoUsageError.apiError("HTTP \(response.statusCode)")
        }
        guard let text = String(data: response.data, encoding: .utf8) else {
            throw OpenCodeGoUsageError.parseFailed("Response was not UTF-8.")
        }
        return try self.parseAPIUsage(text: text, now: now)
    }

    static func requiredZenBalanceFallback(
        from task: Task<Double?, Error>?,
        for error: OpenCodeGoUsageError,
        request: ZenBalanceRequest,
        now: Date) async throws -> OpenCodeGoUsageSnapshot
    {
        switch error {
        case .noSubscription:
            break
        case let .parseFailed(message) where message.contains("Missing usage fields"):
            break
        default:
            throw error
        }
        let task = task ?? Task {
            try await self.fetchZenBalance(
                workspaceID: request.workspaceID,
                cookieHeader: request.cookieHeader,
                timeout: request.timeout,
                session: request.session)
        }
        defer {
            task.cancel()
        }
        let zenBalance = try await self.completedRequiredZenBalance(from: task)
        guard let zenBalance else {
            throw error
        }
        return OpenCodeGoUsageSnapshot.zenBalanceOnly(balanceUSD: zenBalance, updatedAt: now)
    }

    static func fetchOptionalZenBalance(
        cookieHeader: String,
        timeout: TimeInterval,
        workspaceIDOverride: String? = nil,
        session: URLSession? = nil) async throws -> Double?
    {
        let session = session ?? self.redirectGuardSession
        guard let requestCookieHeader = OpenCodeWebCookieSupport.requestCookieHeader(from: cookieHeader) else {
            throw OpenCodeGoUsageError.invalidCredentials
        }
        let requestTimeout = min(timeout, self.optionalZenBalanceTimeout)
        let workspaceID: String = if let override = self.normalizeWorkspaceID(workspaceIDOverride) {
            override
        } else {
            try await self.fetchWorkspaceID(
                cookieHeader: requestCookieHeader,
                timeout: requestTimeout,
                session: session)
        }
        return try await self.fetchOptionalZenBalance(
            workspaceID: workspaceID,
            cookieHeader: requestCookieHeader,
            timeout: requestTimeout,
            session: session)
    }

    static func allowsRedirect(from sourceURL: URL?, to destinationURL: URL?) -> Bool {
        guard let sourceHost = sourceURL?.host?.lowercased(),
              let destinationHost = destinationURL?.host?.lowercased(),
              sourceHost == destinationHost,
              destinationURL?.scheme?.lowercased() == "https"
        else { return false }
        return true
    }

    /// Opens the console route. The legacy `/workspace/<id>/go` page redirects migrated workspaces
    /// to the console login screen, so it is no longer a usable destination.
    public static func dashboardURL(workspaceID raw: String?) -> URL {
        guard let workspaceID = self.normalizeWorkspaceID(raw),
              let url = URL(string: "\(self.baseURL.absoluteString)/console/\(workspaceID)/go")
        else {
            return self.authURL
        }
        return url
    }
}

extension OpenCodeGoUsageFetcher {
    static func fetchZenBillingText(
        workspaceID: String,
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> String
    {
        let argsData = try JSONSerialization.data(withJSONObject: [workspaceID])
        guard let args = String(data: argsData, encoding: .utf8) else {
            throw OpenCodeGoUsageError.parseFailed("Could not encode billing request.")
        }
        return try await self.fetchServerText(
            request: ServerRequest(
                serverID: self.billingServerID,
                args: args,
                method: "GET",
                referer: self.zenDashboardURL(workspaceID: workspaceID)),
            cookieHeader: cookieHeader,
            timeout: timeout,
            session: session)
    }

    private static func fetchWorkspaceID(
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> String
    {
        try await OpenCodeGoLegacyFallback.fetch(cookieHeader: cookieHeader) {
            try await self.fetchConsoleWorkspaceID(cookieHeader: cookieHeader, timeout: timeout, session: session)
        } legacy: {
            try await self.fetchLegacyWorkspaceID(cookieHeader: cookieHeader, timeout: timeout, session: session)
        }
    }

    private static func fetchLegacyWorkspaceID(
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> String
    {
        let text = try await self.fetchServerText(
            request: ServerRequest(
                serverID: self.workspacesServerID,
                args: nil,
                method: "GET",
                referer: self.baseURL),
            cookieHeader: cookieHeader,
            timeout: timeout,
            session: session)
        if self.looksSignedOut(text: text) {
            throw OpenCodeGoUsageError.invalidCredentials
        }
        var ids = OpenCodeWebParsing.parseWorkspaceIDs(text: text)
        if ids.isEmpty {
            ids = OpenCodeWebParsing.parseWorkspaceIDsFromJSON(text: text)
        }
        if ids.isEmpty {
            Self.log.error("OpenCode Go workspace ids missing after GET; retrying with POST.")
            let fallback = try await self.fetchServerText(
                request: ServerRequest(
                    serverID: self.workspacesServerID,
                    args: "[]",
                    method: "POST",
                    referer: self.baseURL),
                cookieHeader: cookieHeader,
                timeout: timeout,
                session: session)
            if self.looksSignedOut(text: fallback) {
                throw OpenCodeGoUsageError.invalidCredentials
            }
            ids = OpenCodeWebParsing.parseWorkspaceIDs(text: fallback)
            if ids.isEmpty {
                ids = OpenCodeWebParsing.parseWorkspaceIDsFromJSON(text: fallback)
            }
            if ids.isEmpty {
                throw OpenCodeGoUsageError.parseFailed("Missing workspace id.")
            }
            return ids[0]
        }
        return ids[0]
    }

    /// Reads the Go subscription payload, preferring the console API.
    ///
    /// Migrated workspaces redirect `opencode.ai/workspace/<id>/go` to the console login route and
    /// answer with an empty SPA shell, so the scraped payload no longer exists. Workspaces that have
    /// not migrated yet still serve the legacy page, which stays as the fallback.
    private static func fetchSubscriptionPayload(
        workspaceID: String,
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> String
    {
        try await OpenCodeGoLegacyFallback.fetch(cookieHeader: cookieHeader) {
            try await self.fetchConsoleGoStatus(
                workspaceID: workspaceID,
                cookieHeader: cookieHeader,
                timeout: timeout,
                session: session)
        } legacy: {
            try await self.fetchUsagePage(
                workspaceID: workspaceID,
                cookieHeader: cookieHeader,
                timeout: timeout,
                session: session)
        }
    }

    private static func fetchUsagePage(
        workspaceID: String,
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> String
    {
        let url = URL(string: "https://opencode.ai/workspace/\(workspaceID)/go") ?? self.baseURL
        let text = try await self.fetchPageText(
            url: url,
            cookieHeader: cookieHeader,
            timeout: timeout,
            session: session)
        if self.looksSignedOut(text: text) {
            throw OpenCodeGoUsageError.invalidCredentials
        }
        guard self.parseSubscriptionJSON(text: text, now: Date()) != nil ||
            OpenCodeWebParsing.extractDouble(
                pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
                text: text) != nil
        else {
            Self.log.error("OpenCode Go usage page payload missing usage fields.")
            throw OpenCodeGoUsageError.parseFailed("Missing usage fields.")
        }
        return text
    }

    // MARK: - Console API

    private static func fetchConsoleWorkspaceID(
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> String
    {
        let text = try await self.fetchConsoleText(
            url: self.consoleWorkspacesURL,
            workspaceID: nil,
            cookieHeader: cookieHeader,
            timeout: timeout,
            session: session)
        guard let workspaceID = self.parseConsoleWorkspaceIDs(text: text).first else {
            throw OpenCodeGoUsageError.parseFailed("Missing workspace id.")
        }
        return workspaceID
    }

    private static func fetchConsoleGoStatus(
        workspaceID: String,
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> String
    {
        let text = try await self.fetchConsoleText(
            url: self.consoleGoStatusURL,
            workspaceID: workspaceID,
            cookieHeader: cookieHeader,
            timeout: timeout,
            session: session)
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           object is NSNull || (object as? [String: Any])?["access"] is NSNull
        {
            throw OpenCodeGoUsageError.noSubscription
        }
        guard self.parseConsoleGoStatus(text: text, now: Date()) != nil else {
            Self.log.error("OpenCode Go console status payload missing usage fields.")
            throw OpenCodeGoUsageError.parseFailed("Invalid Console usage payload.")
        }
        return text
    }

    /// Console responses are JSON and report a signed-out session as HTTP 401, so unlike the legacy
    /// pages they must not be classified by body text.
    static func fetchConsoleText(
        url: URL,
        workspaceID: String?,
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> String
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let workspaceID {
            request.setValue(workspaceID, forHTTPHeaderField: self.consoleWorkspaceHeaderField)
        }

        let httpResponse = try await session.response(for: request)
        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: httpResponse.data, encoding: .utf8) ?? ""
            if httpResponse.statusCode == 401 {
                throw OpenCodeGoUsageError.invalidCredentials
            }
            if let message = OpenCodeWebParsing.extractServerErrorMessage(from: bodyText) {
                throw OpenCodeGoUsageError.apiError("HTTP \(httpResponse.statusCode): \(message)")
            }
            throw OpenCodeGoUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }
        guard let text = String(data: httpResponse.data, encoding: .utf8) else {
            throw OpenCodeGoUsageError.parseFailed("Response was not UTF-8.")
        }
        return text
    }

    static func parseConsoleWorkspaceIDs(text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else {
            return []
        }
        return rows.compactMap { $0["id"] as? String }.filter { self.isConsoleWorkspaceID($0) }
    }

    private static func isConsoleWorkspaceID(_ value: String) -> Bool {
        value.range(of: #"^(?:wrk_|org_)[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    static func normalizeWorkspaceID(_ raw: String?) -> String? {
        if let legacy = OpenCodeWebParsing.normalizeWorkspaceID(raw) { return legacy }
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if self.isConsoleWorkspaceID(raw) { return raw }
        guard let url = URL(string: raw), url.scheme == "https", url.host == "opencode.ai",
              let index = url.pathComponents.firstIndex(of: "console"),
              url.pathComponents.count > index + 1
        else { return nil }
        let candidate = url.pathComponents[index + 1]
        return self.isConsoleWorkspaceID(candidate) ? candidate : nil
    }

    /// Converts the console's micro-cent meters into the percentage windows the snapshot models.
    /// The month meter carries no reset timestamp, so the billing period end stands in for it.
    static func parseConsoleGoStatus(text: String, now: Date) -> OpenCodeGoUsageSnapshot? {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = root["access"] as? [String: Any],
              let meters = access["meters"] as? [String: Any],
              let rolling = meters["fiveHour"] as? [String: Any]
        else {
            return nil
        }

        let renewsAt = OpenCodeWebParsing.dateValue(from: access["endsAt"])
        var monthly = meters["month"] as? [String: Any]
        if monthly?["resetsAt"] == nil || monthly?["resetsAt"] is NSNull, let endsAt = access["endsAt"] {
            monthly?["resetsAt"] = endsAt
        }

        guard let snapshot = self.buildSnapshot(
            rolling: rolling,
            weekly: meters["week"] as? [String: Any],
            monthly: monthly,
            now: now,
            renewsAt: renewsAt)
        else { return nil }

        func resetInterval(_ meter: [String: Any]?) -> Int? {
            OpenCodeWebParsing.dateValue(from: meter?["resetsAt"]).flatMap { OpenCodeWebParsing.resetInterval(
                from: $0,
                now: now) }
        }
        return OpenCodeGoUsageSnapshot(
            hasWeeklyUsage: snapshot.hasWeeklyUsage,
            hasMonthlyUsage: snapshot.hasMonthlyUsage,
            rollingUsagePercent: snapshot.rollingUsagePercent,
            weeklyUsagePercent: snapshot.weeklyUsagePercent,
            monthlyUsagePercent: snapshot.monthlyUsagePercent,
            rollingResetInSec: resetInterval(rolling),
            weeklyResetInSec: resetInterval(meters["week"] as? [String: Any]),
            monthlyResetInSec: resetInterval(monthly),
            renewsAt: renewsAt,
            updatedAt: now)
    }

    static func parseAPIUsage(text: String, now: Date) throws -> OpenCodeGoUsageSnapshot {
        guard let data = text.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = dict["usage"] as? [String: Any],
              let rolling = usage["rolling"] as? [String: Any]
        else {
            throw OpenCodeGoUsageError.parseFailed("Missing usage fields.")
        }
        let renewsAt = OpenCodeWebParsing.dateValue(from: OpenCodeWebParsing.value(
            from: usage,
            keys: OpenCodeWebParsing.renewAtKeys))
            ?? OpenCodeWebParsing.dateValue(from: OpenCodeWebParsing.value(
                from: dict,
                keys: OpenCodeWebParsing.renewAtKeys))
        guard let snapshot = self.buildSnapshot(
            rolling: rolling,
            weekly: usage["weekly"] as? [String: Any],
            monthly: usage["monthly"] as? [String: Any],
            now: now,
            renewsAt: renewsAt,
            directPercentEncoding: .percent)
        else {
            throw OpenCodeGoUsageError.parseFailed("Missing usage fields.")
        }
        return snapshot
    }

    static func parseSubscription(text: String, now: Date) throws -> OpenCodeGoUsageSnapshot {
        if let snapshot = self.parseSubscriptionJSON(text: text, now: now) {
            return snapshot
        }

        guard let rollingPercent = OpenCodeWebParsing.extractDouble(
            pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            text: text),
            let rollingReset = OpenCodeWebParsing.extractInt(
                pattern: #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
                text: text)
        else {
            throw OpenCodeGoUsageError.parseFailed("Missing usage fields.")
        }

        let weeklyPercent = OpenCodeWebParsing.extractDouble(
            pattern: #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            text: text)
        let weeklyReset = OpenCodeWebParsing.extractInt(
            pattern: #"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
            text: text)
        let hasWeeklyUsage = weeklyPercent != nil && weeklyReset != nil

        let monthlyPercent = OpenCodeWebParsing.extractDouble(
            pattern: #"monthlyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            text: text)
        let monthlyReset = OpenCodeWebParsing.extractInt(
            pattern: #"monthlyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
            text: text)

        return OpenCodeGoUsageSnapshot(
            hasWeeklyUsage: hasWeeklyUsage,
            hasMonthlyUsage: monthlyPercent != nil || monthlyReset != nil,
            rollingUsagePercent: rollingPercent,
            weeklyUsagePercent: weeklyPercent ?? 0,
            monthlyUsagePercent: monthlyPercent ?? 0,
            rollingResetInSec: rollingReset,
            weeklyResetInSec: weeklyReset ?? 0,
            monthlyResetInSec: monthlyReset ?? 0,
            updatedAt: now)
    }

    private static func parseSubscriptionJSON(text: String, now: Date) -> OpenCodeGoUsageSnapshot? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else {
            return nil
        }

        // The console reports micro-cent meters, which the generic window parser cannot key on.
        if let snapshot = self.parseConsoleGoStatus(text: text, now: now) {
            return snapshot
        }

        let renewsAt = OpenCodeWebParsing.dateValue(from: OpenCodeWebParsing.value(
            from: dict,
            keys: OpenCodeWebParsing.renewAtKeys))
        if let snapshot = self.parseUsageDictionary(dict, now: now, inheritedRenewsAt: renewsAt) {
            return snapshot
        }
        for key in ["data", "result", "usage", "billing", "payload"] {
            if let nested = dict[key] as? [String: Any],
               let snapshot = self.parseUsageDictionary(nested, now: now, inheritedRenewsAt: renewsAt)
            {
                return snapshot
            }
        }
        if let snapshot = self.parseUsageNested(dict, now: now, depth: 0, inheritedRenewsAt: renewsAt) {
            return snapshot
        }
        return self.parseUsageFromCandidates(object: object, now: now, inheritedRenewsAt: renewsAt)
    }

    private static func parseUsageDictionary(
        _ dict: [String: Any],
        now: Date,
        inheritedRenewsAt: Date?) -> OpenCodeGoUsageSnapshot?
    {
        let renewsAt = OpenCodeWebParsing
            .dateValue(from: OpenCodeWebParsing.value(from: dict, keys: OpenCodeWebParsing.renewAtKeys)) ??
            inheritedRenewsAt
        if let usage = dict["usage"] as? [String: Any],
           let snapshot = self.parseUsageDictionary(usage, now: now, inheritedRenewsAt: renewsAt)
        {
            return snapshot
        }

        let rollingKeys = ["rollingUsage", "rolling", "rolling_usage", "rollingWindow", "rolling_window"]
        let weeklyKeys = ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow", "weekly_window"]
        let monthlyKeys = ["monthlyUsage", "monthly", "monthly_usage", "monthlyWindow", "monthly_window"]

        let rolling = self.firstDict(from: dict, keys: rollingKeys)
        let weekly = self.firstDict(from: dict, keys: weeklyKeys)
        let monthly = self.firstDict(from: dict, keys: monthlyKeys)

        guard let rolling else { return nil }

        return self.buildSnapshot(rolling: rolling, weekly: weekly, monthly: monthly, now: now, renewsAt: renewsAt)
    }

    private static func parseUsageNested(
        _ dict: [String: Any],
        now: Date,
        depth: Int,
        inheritedRenewsAt: Date?) -> OpenCodeGoUsageSnapshot?
    {
        if depth > 3 { return nil }
        let renewsAt = OpenCodeWebParsing
            .dateValue(from: OpenCodeWebParsing.value(from: dict, keys: OpenCodeWebParsing.renewAtKeys)) ??
            inheritedRenewsAt
        var rolling: [String: Any]?
        var weekly: [String: Any]?
        var monthly: [String: Any]?

        for (key, value) in dict {
            guard let sub = value as? [String: Any] else { continue }
            let lower = key.lowercased()
            if lower.contains("rolling") || lower.contains("hour") || lower.contains("5h") || lower.contains("5-hour") {
                rolling = sub
            } else if lower.contains("weekly") || lower.contains("week") {
                weekly = sub
            } else if lower.contains("monthly") || lower.contains("month") {
                monthly = sub
            }
        }

        if let rolling {
            let snapshot = self.buildSnapshot(
                rolling: rolling,
                weekly: weekly,
                monthly: monthly,
                now: now,
                renewsAt: renewsAt)
            if let snapshot { return snapshot }
        }

        for value in dict.values {
            if let sub = value as? [String: Any],
               let snapshot = self.parseUsageNested(
                   sub,
                   now: now,
                   depth: depth + 1,
                   inheritedRenewsAt: renewsAt)
            {
                return snapshot
            }
        }

        return nil
    }

    private static func parseUsageFromCandidates(
        object: Any,
        now: Date,
        inheritedRenewsAt: Date? = nil) -> OpenCodeGoUsageSnapshot?
    {
        let candidates = OpenCodeWebParsing.collectWindowCandidates(object: object) { self.parseWindow($0, now: now) }
        guard !candidates.isEmpty else { return nil }

        let rollingCandidates = candidates.filter { candidate in
            candidate.pathLower.contains("rolling") ||
                candidate.pathLower.contains("hour") ||
                candidate.pathLower.contains("5h") ||
                candidate.pathLower.contains("5-hour")
        }
        let weeklyCandidates = candidates.filter { candidate in
            candidate.pathLower.contains("weekly") ||
                candidate.pathLower.contains("week")
        }
        let monthlyCandidates = candidates.filter { candidate in
            candidate.pathLower.contains("monthly") ||
                candidate.pathLower.contains("month")
        }

        let nonRollingIDs = Set((weeklyCandidates + monthlyCandidates).map(\.id))
        let rolling = OpenCodeWebParsing.pickCandidate(
            preferred: rollingCandidates,
            fallback: candidates.filter { !nonRollingIDs.contains($0.id) },
            pickShorter: true)
        let weekly = OpenCodeWebParsing.pickCandidate(
            from: weeklyCandidates.filter { candidate in
                candidate.id != rolling?.id
            },
            pickShorter: false)
        let monthly = OpenCodeWebParsing.pickCandidate(
            from: monthlyCandidates.filter { candidate in
                candidate.id != rolling?.id && candidate.id != weekly?.id
            },
            pickShorter: false)

        guard let rolling else { return nil }

        let renewsAt = OpenCodeWebParsing.dateValue(from: OpenCodeWebParsing.value(
            from: object as? [String: Any] ?? [:],
            keys: OpenCodeWebParsing.renewAtKeys))
            ?? inheritedRenewsAt
        return OpenCodeGoUsageSnapshot(
            hasWeeklyUsage: weekly != nil,
            hasMonthlyUsage: monthly != nil,
            rollingUsagePercent: rolling.percent,
            weeklyUsagePercent: weekly?.percent ?? 0,
            monthlyUsagePercent: monthly?.percent ?? 0,
            rollingResetInSec: rolling.resetInSec,
            weeklyResetInSec: weekly?.resetInSec ?? 0,
            monthlyResetInSec: monthly?.resetInSec ?? 0,
            renewsAt: renewsAt,
            updatedAt: now)
    }

    private static func firstDict(from dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] {
                return value
            }
        }
        return nil
    }

    private enum DirectPercentEncoding {
        case percent
        case fractionOrPercent
    }

    private static func buildSnapshot(
        rolling: [String: Any],
        weekly: [String: Any]?,
        monthly: [String: Any]?,
        now: Date,
        renewsAt: Date? = nil,
        directPercentEncoding: DirectPercentEncoding = .fractionOrPercent) -> OpenCodeGoUsageSnapshot?
    {
        guard let rollingWindow = self.parseWindow(rolling, now: now, directPercentEncoding: directPercentEncoding)
        else {
            return nil
        }

        let weeklyWindow: (percent: Double, resetInSec: Int)?
        if let weekly {
            guard let parsed = self.parseWindow(weekly, now: now, directPercentEncoding: directPercentEncoding)
            else { return nil }
            weeklyWindow = parsed
        } else {
            weeklyWindow = nil
        }
        let monthlyWindow = monthly.flatMap {
            self.parseWindow($0, now: now, directPercentEncoding: directPercentEncoding)
        }

        return OpenCodeGoUsageSnapshot(
            hasWeeklyUsage: weeklyWindow != nil,
            hasMonthlyUsage: monthlyWindow != nil,
            rollingUsagePercent: rollingWindow.percent,
            weeklyUsagePercent: weeklyWindow?.percent ?? 0,
            monthlyUsagePercent: monthlyWindow?.percent ?? 0,
            rollingResetInSec: rollingWindow.resetInSec,
            weeklyResetInSec: weeklyWindow?.resetInSec ?? 0,
            monthlyResetInSec: monthlyWindow?.resetInSec ?? 0,
            renewsAt: renewsAt,
            updatedAt: now)
    }

    private static func parseWindow(
        _ dict: [String: Any],
        now: Date,
        directPercentEncoding: DirectPercentEncoding = .fractionOrPercent) -> (percent: Double, resetInSec: Int)?
    {
        var percent = OpenCodeWebParsing.doubleValue(from: dict, keys: OpenCodeWebParsing.percentKeys)
        // Dashboard JSON may use fractions. API fields and computed used/limit percentages already use 0...100.
        let percentIsDirect = percent != nil

        if percent == nil {
            let usedKeys = ["used", "usage", "consumed", "count", "usedTokens", "usedMicroCents"]
            let limitKeys = ["limit", "total", "quota", "max", "cap", "tokenLimit", "limitMicroCents"]
            let used = OpenCodeWebParsing.doubleValue(from: dict, keys: usedKeys)
            let limit = OpenCodeWebParsing.doubleValue(from: dict, keys: limitKeys)
            if let used, let limit, limit > 0 {
                percent = (used / limit) * 100
            }
        }

        guard var resolvedPercent = percent else { return nil }
        if percentIsDirect, directPercentEncoding == .fractionOrPercent, resolvedPercent <= 1.0, resolvedPercent >= 0 {
            resolvedPercent *= 100
        }
        resolvedPercent = max(0, min(100, resolvedPercent))

        var resetInSec = OpenCodeWebParsing.intValue(from: dict, keys: OpenCodeWebParsing.resetInKeys)

        if resetInSec == nil {
            for key in OpenCodeWebParsing.resetAtKeys {
                if let resetAt = OpenCodeWebParsing.dateValue(from: dict[key]),
                   let interval = OpenCodeWebParsing.resetInterval(from: resetAt, now: now)
                {
                    resetInSec = interval
                    break
                }
            }
        }

        let resolvedReset = max(0, resetInSec ?? 0)
        return (resolvedPercent, resolvedReset)
    }

    private static func fetchServerText(
        request serverRequest: ServerRequest,
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> String
    {
        let url = self.serverRequestURL(
            serverID: serverRequest.serverID,
            args: serverRequest.args,
            method: serverRequest.method)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = serverRequest.method
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        urlRequest.setValue(serverRequest.serverID, forHTTPHeaderField: "X-Server-Id")
        urlRequest.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        urlRequest.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue(self.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        urlRequest.setValue(serverRequest.referer.absoluteString, forHTTPHeaderField: "Referer")
        urlRequest.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        if serverRequest.method.uppercased() != "GET",
           let args = serverRequest.args
        {
            urlRequest.httpBody = args.data(using: .utf8)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let httpResponse = try await session.response(for: urlRequest)

        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: httpResponse.data, encoding: .utf8) ?? ""
            let contentType = httpResponse.response.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            let dataLength = httpResponse.data.count
            Self.log.error(
                "OpenCode Go returned \(httpResponse.statusCode) (type=\(contentType) length=\(dataLength))")
            if self.looksSignedOut(text: bodyText) {
                throw OpenCodeGoUsageError.invalidCredentials
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw OpenCodeGoUsageError.invalidCredentials
            }
            if let message = OpenCodeWebParsing.extractServerErrorMessage(from: bodyText) {
                throw OpenCodeGoUsageError.apiError("HTTP \(httpResponse.statusCode): \(message)")
            }
            throw OpenCodeGoUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let text = String(data: httpResponse.data, encoding: .utf8) else {
            throw OpenCodeGoUsageError.parseFailed("Response was not UTF-8.")
        }
        return text
    }

    static func fetchPageText(
        url: URL,
        cookieHeader: String,
        timeout: TimeInterval,
        session: URLSession) async throws -> String
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")

        let httpResponse = try await session.response(for: request)
        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: httpResponse.data, encoding: .utf8) ?? ""
            if self.looksSignedOut(text: bodyText) {
                throw OpenCodeGoUsageError.invalidCredentials
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw OpenCodeGoUsageError.invalidCredentials
            }
            if let message = OpenCodeWebParsing.extractServerErrorMessage(from: bodyText) {
                throw OpenCodeGoUsageError.apiError("HTTP \(httpResponse.statusCode): \(message)")
            }
            throw OpenCodeGoUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }
        guard let text = String(data: httpResponse.data, encoding: .utf8) else {
            throw OpenCodeGoUsageError.parseFailed("Response was not UTF-8.")
        }
        return text
    }

    private static func serverRequestURL(serverID: String, args: String?, method: String) -> URL {
        guard method.uppercased() == "GET" else {
            return self.serverURL
        }

        var components = URLComponents(url: self.serverURL, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "id", value: serverID)]
        if let args, !args.isEmpty {
            queryItems.append(URLQueryItem(name: "args", value: args))
        }
        components?.queryItems = queryItems
        return components?.url ?? self.serverURL
    }

    static func looksSignedOut(text: String) -> Bool {
        OpenCodeWebParsing.looksSignedOut(text: text)
    }
}
