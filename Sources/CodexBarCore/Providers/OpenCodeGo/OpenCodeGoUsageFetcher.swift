import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OpenCodeGoUsageError: LocalizedError {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "OpenCode Go session cookie is invalid or expired."
        case let .networkError(message):
            "OpenCode Go network error: \(message)"
        case let .apiError(message):
            "OpenCode Go API error: \(message)"
        case let .parseFailed(message):
            "OpenCode Go parse error: \(message)"
        }
    }
}

public struct OpenCodeGoUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.opencodeGoUsage)
    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private struct ServerRequest {
        let serverID: String
        let args: String?
        let method: String
        let referer: URL
    }

    private static let percentKeys = [
        "usagePercent",
        "usedPercent",
        "percentUsed",
        "percent",
        "usage_percent",
        "used_percent",
        "utilization",
        "utilizationPercent",
        "utilization_percent",
        "usage",
    ]
    private static let resetInKeys = [
        "resetInSec",
        "resetInSeconds",
        "resetSeconds",
        "reset_sec",
        "reset_in_sec",
        "resetsInSec",
        "resetsInSeconds",
        "resetIn",
        "resetSec",
    ]
    private static let resetAtKeys = [
        "resetAt",
        "resetsAt",
        "reset_at",
        "resets_at",
        "nextReset",
        "next_reset",
        "renewAt",
        "renew_at",
    ]

    public static func fetchUsage(
        cookieHeader: String,
        timeout: TimeInterval,
        now: Date = Date(),
        workspaceIDOverride: String? = nil,
        session: URLSession = .shared) async throws -> OpenCodeGoUsageSnapshot
    {
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
        let subscriptionText = try await self.fetchUsagePage(
            workspaceID: workspaceID,
            cookieHeader: requestCookieHeader,
            timeout: timeout,
            session: session)
        return try self.parseSubscription(text: subscriptionText, now: now)
    }

    public static func dashboardURL(workspaceID raw: String?) -> URL {
        guard let workspaceID = self.normalizeWorkspaceID(raw),
              let url = URL(string: "\(self.baseURL.absoluteString)/workspace/\(workspaceID)/go")
        else {
            return self.baseURL
        }
        return url
    }

    private static func fetchWorkspaceID(
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
        var ids = self.parseWorkspaceIDs(text: text)
        if ids.isEmpty {
            ids = self.parseWorkspaceIDsFromJSON(text: text)
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
            ids = self.parseWorkspaceIDs(text: fallback)
            if ids.isEmpty {
                ids = self.parseWorkspaceIDsFromJSON(text: fallback)
            }
            if ids.isEmpty {
                throw OpenCodeGoUsageError.parseFailed("Missing workspace id.")
            }
            return ids[0]
        }
        return ids[0]
    }

    private static func normalizeWorkspaceID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("wrk_"), trimmed.count > 4 {
            return trimmed
        }
        if let url = URL(string: trimmed) {
            let parts = url.pathComponents
            if let index = parts.firstIndex(of: "workspace"),
               parts.count > index + 1
            {
                let candidate = parts[index + 1]
                if candidate.hasPrefix("wrk_"), candidate.count > 4 {
                    return candidate
                }
            }
        }
        if let match = trimmed.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return nil
    }

    static func parseWorkspaceIDs(text: String) -> [String] {
        let pattern = #"id\s*:\s*\"(wrk_[^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsrange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func parseWorkspaceIDsFromJSON(text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return []
        }
        var results: [String] = []
        self.collectWorkspaceIDs(object: object, out: &results)
        return results
    }

    private static func collectWorkspaceIDs(object: Any, out: inout [String]) {
        if let dict = object as? [String: Any] {
            for (_, value) in dict {
                self.collectWorkspaceIDs(object: value, out: &out)
            }
            return
        }
        if let array = object as? [Any] {
            for value in array {
                self.collectWorkspaceIDs(object: value, out: &out)
            }
            return
        }
        if let string = object as? String,
           string.hasPrefix("wrk_"),
           !out.contains(string)
        {
            out.append(string)
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
            self.extractDouble(
                pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
                text: text) != nil
        else {
            Self.log.error("OpenCode Go usage page payload missing usage fields.")
            throw OpenCodeGoUsageError.parseFailed("Missing usage fields.")
        }
        return text
    }

    static func parseSubscription(text: String, now: Date) throws -> OpenCodeGoUsageSnapshot {
        if let snapshot = self.parseSubscriptionJSON(text: text, now: now) {
            return snapshot
        }

        guard let rollingPercent = self.extractDouble(
            pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            text: text),
            let rollingReset = self.extractInt(
                pattern: #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
                text: text),
            let weeklyPercent = self.extractDouble(
                pattern: #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
                text: text),
            let weeklyReset = self.extractInt(
                pattern: #"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
                text: text)
        else {
            throw OpenCodeGoUsageError.parseFailed("Missing usage fields.")
        }

        let monthlyPercent = self.extractDouble(
            pattern: #"monthlyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            text: text)
        let monthlyReset = self.extractInt(
            pattern: #"monthlyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
            text: text)

        return OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: monthlyPercent != nil || monthlyReset != nil,
            rollingUsagePercent: rollingPercent,
            weeklyUsagePercent: weeklyPercent,
            monthlyUsagePercent: monthlyPercent ?? 0,
            rollingResetInSec: rollingReset,
            weeklyResetInSec: weeklyReset,
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

        if let snapshot = self.parseUsageDictionary(dict, now: now) {
            return snapshot
        }
        for key in ["data", "result", "usage", "billing", "payload"] {
            if let nested = dict[key] as? [String: Any],
               let snapshot = self.parseUsageDictionary(nested, now: now)
            {
                return snapshot
            }
        }
        if let snapshot = self.parseUsageNested(dict, now: now, depth: 0) {
            return snapshot
        }
        return self.parseUsageFromCandidates(object: object, now: now)
    }

    private static func parseUsageDictionary(_ dict: [String: Any], now: Date) -> OpenCodeGoUsageSnapshot? {
        if let usage = dict["usage"] as? [String: Any],
           let snapshot = self.parseUsageDictionary(usage, now: now)
        {
            return snapshot
        }

        let rollingKeys = ["rollingUsage", "rolling", "rolling_usage", "rollingWindow", "rolling_window"]
        let weeklyKeys = ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow", "weekly_window"]
        let monthlyKeys = ["monthlyUsage", "monthly", "monthly_usage", "monthlyWindow", "monthly_window"]

        let rolling = self.firstDict(from: dict, keys: rollingKeys)
        let weekly = self.firstDict(from: dict, keys: weeklyKeys)
        let monthly = self.firstDict(from: dict, keys: monthlyKeys)

        guard let rolling, let weekly else { return nil }

        return self.buildSnapshot(rolling: rolling, weekly: weekly, monthly: monthly, now: now)
    }

    private static func parseUsageNested(_ dict: [String: Any], now: Date, depth: Int) -> OpenCodeGoUsageSnapshot? {
        if depth > 3 { return nil }
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

        if let rolling, let weekly,
           let snapshot = self.buildSnapshot(rolling: rolling, weekly: weekly, monthly: monthly, now: now)
        {
            return snapshot
        }

        for value in dict.values {
            if let sub = value as? [String: Any],
               let snapshot = self.parseUsageNested(sub, now: now, depth: depth + 1)
            {
                return snapshot
            }
        }

        return nil
    }

    private static func parseUsageFromCandidates(object: Any, now: Date) -> OpenCodeGoUsageSnapshot? {
        let candidates = self.collectWindowCandidates(object: object, now: now)
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

        let rolling = self.pickCandidate(
            preferred: rollingCandidates,
            fallback: candidates,
            pickShorter: true)
        let weekly = self.pickCandidate(
            from: weeklyCandidates.filter { candidate in
                candidate.id != rolling?.id
            },
            pickShorter: false)
        let monthly = self.pickCandidate(
            from: monthlyCandidates.filter { candidate in
                candidate.id != rolling?.id && candidate.id != weekly?.id
            },
            pickShorter: false)

        guard let rolling, let weekly else { return nil }

        return OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: monthly != nil,
            rollingUsagePercent: rolling.percent,
            weeklyUsagePercent: weekly.percent,
            monthlyUsagePercent: monthly?.percent ?? 0,
            rollingResetInSec: rolling.resetInSec,
            weeklyResetInSec: weekly.resetInSec,
            monthlyResetInSec: monthly?.resetInSec ?? 0,
            updatedAt: now)
    }

    private struct WindowCandidate {
        let id: UUID
        let percent: Double
        let resetInSec: Int
        let pathLower: String
    }

    private static func collectWindowCandidates(object: Any, now: Date) -> [WindowCandidate] {
        var candidates: [WindowCandidate] = []
        self.collectWindowCandidates(object: object, now: now, path: [], out: &candidates)
        return candidates
    }

    private static func collectWindowCandidates(
        object: Any,
        now: Date,
        path: [String],
        out: inout [WindowCandidate])
    {
        if let dict = object as? [String: Any] {
            if let window = self.parseWindow(dict, now: now) {
                let pathLower = path.joined(separator: ".").lowercased()
                out.append(WindowCandidate(
                    id: UUID(),
                    percent: window.percent,
                    resetInSec: window.resetInSec,
                    pathLower: pathLower))
            }
            for (key, value) in dict {
                self.collectWindowCandidates(object: value, now: now, path: path + [key], out: &out)
            }
            return
        }

        if let array = object as? [Any] {
            for (index, value) in array.enumerated() {
                self.collectWindowCandidates(
                    object: value,
                    now: now,
                    path: path + ["[\(index)]"],
                    out: &out)
            }
        }
    }

    private static func pickCandidate(
        preferred: [WindowCandidate],
        fallback: [WindowCandidate],
        pickShorter: Bool,
        excluding excluded: UUID? = nil) -> WindowCandidate?
    {
        let filteredPreferred = preferred.filter { $0.id != excluded }
        if let picked = self.pickCandidate(from: filteredPreferred, pickShorter: pickShorter) {
            return picked
        }
        let filteredFallback = fallback.filter { $0.id != excluded }
        return self.pickCandidate(from: filteredFallback, pickShorter: pickShorter)
    }

    private static func pickCandidate(from candidates: [WindowCandidate], pickShorter: Bool) -> WindowCandidate? {
        guard !candidates.isEmpty else { return nil }
        let comparator: (WindowCandidate, WindowCandidate) -> Bool = { lhs, rhs in
            if pickShorter {
                if lhs.resetInSec == rhs.resetInSec { return lhs.percent > rhs.percent }
                return lhs.resetInSec < rhs.resetInSec
            }
            if lhs.resetInSec == rhs.resetInSec { return lhs.percent > rhs.percent }
            return lhs.resetInSec > rhs.resetInSec
        }
        return candidates.min(by: comparator)
    }

    private static func firstDict(from dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] {
                return value
            }
        }
        return nil
    }

    private static func buildSnapshot(
        rolling: [String: Any],
        weekly: [String: Any],
        monthly: [String: Any]?,
        now: Date) -> OpenCodeGoUsageSnapshot?
    {
        guard let rollingWindow = self.parseWindow(rolling, now: now),
              let weeklyWindow = self.parseWindow(weekly, now: now)
        else {
            return nil
        }

        let monthlyWindow = monthly.flatMap { self.parseWindow($0, now: now) }

        return OpenCodeGoUsageSnapshot(
            hasMonthlyUsage: monthlyWindow != nil,
            rollingUsagePercent: rollingWindow.percent,
            weeklyUsagePercent: weeklyWindow.percent,
            monthlyUsagePercent: monthlyWindow?.percent ?? 0,
            rollingResetInSec: rollingWindow.resetInSec,
            weeklyResetInSec: weeklyWindow.resetInSec,
            monthlyResetInSec: monthlyWindow?.resetInSec ?? 0,
            updatedAt: now)
    }

    private static func parseWindow(_ dict: [String: Any], now: Date) -> (percent: Double, resetInSec: Int)? {
        var percent: Double?

        for key in self.percentKeys {
            if let value = self.doubleValue(from: dict[key]) {
                percent = value
                break
            }
        }

        if percent == nil {
            let usedKeys = ["used", "usage", "consumed", "count", "usedTokens"]
            let limitKeys = ["limit", "total", "quota", "max", "cap", "tokenLimit"]
            var used: Double?
            for key in usedKeys {
                if let value = self.doubleValue(from: dict[key]) {
                    used = value
                    break
                }
            }
            var limit: Double?
            for key in limitKeys {
                if let value = self.doubleValue(from: dict[key]) {
                    limit = value
                    break
                }
            }
            if let used, let limit, limit > 0 {
                percent = (used / limit) * 100
            }
        }

        guard var resolvedPercent = percent else { return nil }
        if resolvedPercent <= 1.0, resolvedPercent >= 0 {
            resolvedPercent *= 100
        }
        resolvedPercent = max(0, min(100, resolvedPercent))

        var resetInSec: Int?
        for key in self.resetInKeys {
            if let value = self.intValue(from: dict[key]) {
                resetInSec = value
                break
            }
        }

        if resetInSec == nil {
            for key in self.resetAtKeys {
                if let resetAt = self.dateValue(from: dict[key]) {
                    resetInSec = max(0, Int(resetAt.timeIntervalSince(now)))
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

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeGoUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            Self.log.error("OpenCode Go returned \(httpResponse.statusCode) (type=\(contentType) length=\(data.count))")
            if self.looksSignedOut(text: bodyText) {
                throw OpenCodeGoUsageError.invalidCredentials
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw OpenCodeGoUsageError.invalidCredentials
            }
            if let message = self.extractServerErrorMessage(from: bodyText) {
                throw OpenCodeGoUsageError.apiError("HTTP \(httpResponse.statusCode): \(message)")
            }
            throw OpenCodeGoUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeGoUsageError.parseFailed("Response was not UTF-8.")
        }
        return text
    }

    private static func fetchPageText(
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

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeGoUsageError.networkError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if self.looksSignedOut(text: bodyText) {
                throw OpenCodeGoUsageError.invalidCredentials
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw OpenCodeGoUsageError.invalidCredentials
            }
            if let message = self.extractServerErrorMessage(from: bodyText) {
                throw OpenCodeGoUsageError.apiError("HTTP \(httpResponse.statusCode): \(message)")
            }
            throw OpenCodeGoUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
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

    private static func looksSignedOut(text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("login") ||
            lower.contains("sign in") ||
            lower.contains("auth/authorize") ||
            lower.contains("not associated with an account") ||
            lower.contains("actor of type \"public\"")
    }

    private static func extractServerErrorMessage(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            if let match = text.range(of: #"(?i)<title>([^<]+)</title>"#, options: .regularExpression) {
                return String(text[match].dropFirst(7).dropLast(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }

        guard let dict = object as? [String: Any] else { return nil }
        if let message = dict["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = dict["error"] as? String, !error.isEmpty {
            return error
        }
        if let detail = dict["detail"] as? String, !detail.isEmpty {
            return detail
        }
        return nil
    }

    private static func extractDouble(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Double(text[range])
    }

    private static func extractInt(pattern: String, text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[range])
    }

    private static func doubleValue(from value: Any?) -> Double? {
        switch value {
        case let number as Double:
            number
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func intValue(from value: Any?) -> Int? {
        switch value {
        case let number as Int:
            number
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func dateValue(from value: Any?) -> Date? {
        guard let value else { return nil }
        if let number = self.doubleValue(from: value) {
            if number > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: number / 1000)
            }
            if number > 1_000_000_000 {
                return Date(timeIntervalSince1970: number)
            }
        }
        if let string = value as? String {
            if let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return self.dateValue(from: number)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: string) {
                return parsed
            }
        }
        return nil
    }
}
