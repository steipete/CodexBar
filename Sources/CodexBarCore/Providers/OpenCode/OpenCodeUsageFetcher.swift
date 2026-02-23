import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OpenCodeUsageError: LocalizedError {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "OpenCode session cookie is invalid or expired."
        case let .networkError(message):
            "OpenCode network error: \(message)"
        case let .apiError(message):
            "OpenCode API error: \(message)"
        case let .parseFailed(message):
            "OpenCode parse error: \(message)"
        }
    }
}

public struct OpenCodeUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.opencodeUsage)
    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let subscriptionServerID = "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"
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
    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private struct ServerRequest {
        let serverID: String
        let args: [Any]?
        let method: String
        let referer: URL
    }

    public static func fetchUsage(
        cookieHeader: String,
        timeout: TimeInterval,
        now: Date = Date(),
        workspaceIDOverride: String? = nil) async throws -> OpenCodeUsageSnapshot
    {
        let workspaceID: String = if let override = self.normalizeWorkspaceID(workspaceIDOverride) {
            override
        } else {
            try await self.fetchWorkspaceID(
                cookieHeader: cookieHeader,
                timeout: timeout)
        }
        let subscriptionText = try await self.fetchSubscriptionInfo(
            workspaceID: workspaceID,
            cookieHeader: cookieHeader,
            timeout: timeout)
        return try self.parseSubscription(text: subscriptionText, now: now)
    }

    private static func fetchWorkspaceID(
        cookieHeader: String,
        timeout: TimeInterval) async throws -> String
    {
        let text = try await self.fetchServerText(
            request: ServerRequest(
                serverID: self.workspacesServerID,
                args: nil,
                method: "GET",
                referer: self.baseURL),
            cookieHeader: cookieHeader,
            timeout: timeout)
        if self.looksSignedOut(text: text) {
            throw OpenCodeUsageError.invalidCredentials
        }
        var ids = self.parseWorkspaceIDs(text: text)
        if ids.isEmpty {
            ids = self.parseWorkspaceIDsFromJSON(text: text)
        }
        if ids.isEmpty {
            Self.log.error("OpenCode workspace ids missing after GET; retrying with POST.")
            let fallback = try await self.fetchServerText(
                request: ServerRequest(
                    serverID: self.workspacesServerID,
                    args: [],
                    method: "POST",
                    referer: self.baseURL),
                cookieHeader: cookieHeader,
                timeout: timeout)
            if self.looksSignedOut(text: fallback) {
                throw OpenCodeUsageError.invalidCredentials
            }
            ids = self.parseWorkspaceIDs(text: fallback)
            if ids.isEmpty {
                ids = self.parseWorkspaceIDsFromJSON(text: fallback)
            }
            if ids.isEmpty {
                self.logParseSummary(text: fallback)
                throw OpenCodeUsageError.parseFailed("Missing workspace id.")
            }
            return ids[0]
        }
        return ids[0]
    }

    private static func fetchSubscriptionInfo(
        workspaceID: String,
        cookieHeader: String,
        timeout: TimeInterval) async throws -> String
    {
        let referer = URL(string: "https://opencode.ai/workspace/\(workspaceID)/billing") ?? self.baseURL
        let text = try await self.fetchServerText(
            request: ServerRequest(
                serverID: self.subscriptionServerID,
                args: [workspaceID],
                method: "GET",
                referer: referer),
            cookieHeader: cookieHeader,
            timeout: timeout)
        if self.looksSignedOut(text: text) {
            throw OpenCodeUsageError.invalidCredentials
        }
        if self.isExplicitNullPayload(text: text) {
            Self.log.warning("OpenCode subscription GET returned null; skipping POST fallback.")
            throw self.missingSubscriptionDataError(workspaceID: workspaceID)
        }
        if self.parseSubscriptionJSON(text: text, now: Date()) == nil,
           self.extractDouble(
               pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
               text: text) == nil
        {
            Self.log.error("OpenCode subscription payload missing after GET; retrying with POST.")
            let fallback = try await self.fetchServerText(
                request: ServerRequest(
                    serverID: self.subscriptionServerID,
                    args: [workspaceID],
                    method: "POST",
                    referer: referer),
                cookieHeader: cookieHeader,
                timeout: timeout)
            if self.looksSignedOut(text: fallback) {
                throw OpenCodeUsageError.invalidCredentials
            }
            if self.isExplicitNullPayload(text: fallback) {
                Self.log.warning("OpenCode subscription POST returned null.")
                throw self.missingSubscriptionDataError(workspaceID: workspaceID)
            }
            return fallback
        }
        return text
    }

    private static func isExplicitNullPayload(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("null") == .orderedSame {
            return true
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return false
        }
        return object is NSNull
    }

    private static func missingSubscriptionDataError(workspaceID: String) -> OpenCodeUsageError {
        OpenCodeUsageError.apiError(
            "No subscription usage data was returned for workspace \(workspaceID). " +
                "This usually means this workspace does not have OpenCode Black usage data.")
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

    private static func fetchServerText(
        request serverRequest: ServerRequest,
        cookieHeader: String,
        timeout: TimeInterval) async throws -> String
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
            let body = try JSONSerialization.data(withJSONObject: args, options: [])
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            Self.log.error("OpenCode returned \(httpResponse.statusCode) (type=\(contentType) length=\(data.count))")
            if self.looksSignedOut(text: bodyText) {
                throw OpenCodeUsageError.invalidCredentials
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw OpenCodeUsageError.invalidCredentials
            }
            if let message = self.extractServerErrorMessage(from: bodyText) {
                throw OpenCodeUsageError.apiError("HTTP \(httpResponse.statusCode): \(message)")
            }
            throw OpenCodeUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeUsageError.parseFailed("Response was not UTF-8.")
        }
        return text
    }

    static func parseSubscription(text: String, now: Date) throws -> OpenCodeUsageSnapshot {
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
            self.logParseSummary(text: text)
            throw OpenCodeUsageError.parseFailed("Missing usage fields.")
        }

        return OpenCodeUsageSnapshot(
            rollingUsagePercent: rollingPercent,
            weeklyUsagePercent: weeklyPercent,
            rollingResetInSec: rollingReset,
            weeklyResetInSec: weeklyReset,
            updatedAt: now)
    }

    private static func parseSubscriptionJSON(text: String, now: Date) -> OpenCodeUsageSnapshot? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return nil
        }

        if let snapshot = self.parseUsageJSON(object: object, now: now) {
            return snapshot
        }

        if let snapshot = self.parseUsageFromCandidates(object: object, now: now) {
            return snapshot
        }

        self.logParseSummary(object: object)
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

    private static func looksSignedOut(text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("login") || lower.contains("sign in") || lower.contains("auth/authorize") {
            return true
        }
        return false
    }

    private static func extractServerErrorMessage(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            // If it's not JSON, try to extract error from HTML if possible
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
        // Check for common error fields in some frameworks
        if let detail = dict["detail"] as? String, !detail.isEmpty {
            return detail
        }
        return nil
    }

    private static func serverRequestURL(serverID: String, args: [Any]?, method: String) -> URL {
        guard method.uppercased() == "GET" else {
            return self.serverURL
        }

        var components = URLComponents(url: self.serverURL, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "id", value: serverID)]
        if let args, !args.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: args, options: []),
           let encodedArgs = String(data: data, encoding: .utf8)
        {
            queryItems.append(URLQueryItem(name: "args", value: encodedArgs))
        }
        components?.queryItems = queryItems
        return components?.url ?? self.serverURL
    }

    private static func parseUsageJSON(object: Any, now: Date) -> OpenCodeUsageSnapshot? {
        guard let dict = object as? [String: Any] else { return nil }
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

        return self.parseUsageNested(dict, now: now, depth: 0)
    }

    private static func parseUsageDictionary(_ dict: [String: Any], now: Date) -> OpenCodeUsageSnapshot? {
        if let usage = dict["usage"] as? [String: Any],
           let snapshot = self.parseUsageDictionary(usage, now: now)
        {
            return snapshot
        }

        let rollingKeys = ["rollingUsage", "rolling", "rolling_usage", "rollingWindow", "rolling_window"]
        let weeklyKeys = ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow", "weekly_window"]

        let rolling = rollingKeys.compactMap { dict[$0] as? [String: Any] }.first
        let weekly = weeklyKeys.compactMap { dict[$0] as? [String: Any] }.first

        if let rolling, let weekly {
            return self.buildSnapshot(rolling: rolling, weekly: weekly, now: now)
        }

        return nil
    }

    private static func parseUsageNested(_ dict: [String: Any], now: Date, depth: Int) -> OpenCodeUsageSnapshot? {
        if depth > 3 { return nil }
        var rolling: [String: Any]?
        var weekly: [String: Any]?

        for (key, value) in dict {
            guard let sub = value as? [String: Any] else { continue }
            let lower = key.lowercased()
            if lower.contains("rolling") {
                rolling = sub
            } else if lower.contains("weekly") || lower.contains("week") {
                weekly = sub
            }
        }

        if let rolling, let weekly,
           let snapshot = self.buildSnapshot(rolling: rolling, weekly: weekly, now: now)
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

    private static func parseUsageFromCandidates(object: Any, now: Date) -> OpenCodeUsageSnapshot? {
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

        let rolling = self.pickCandidate(
            preferred: rollingCandidates,
            fallback: candidates,
            pickShorter: true)
        let weekly = self.pickCandidate(
            preferred: weeklyCandidates,
            fallback: candidates,
            pickShorter: false,
            excluding: rolling?.id)

        guard let rolling, let weekly else { return nil }

        return OpenCodeUsageSnapshot(
            rollingUsagePercent: rolling.percent,
            weeklyUsagePercent: weekly.percent,
            rollingResetInSec: rolling.resetInSec,
            weeklyResetInSec: weekly.resetInSec,
            updatedAt: now)
    }

    private struct WindowCandidate: Sendable {
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

    private static func buildSnapshot(
        rolling: [String: Any],
        weekly: [String: Any],
        now: Date) -> OpenCodeUsageSnapshot?
    {
        guard let rollingWindow = self.parseWindow(rolling, now: now),
              let weeklyWindow = self.parseWindow(weekly, now: now)
        else {
            return nil
        }

        return OpenCodeUsageSnapshot(
            rollingUsagePercent: rollingWindow.percent,
            weeklyUsagePercent: weeklyWindow.percent,
            rollingResetInSec: rollingWindow.resetInSec,
            weeklyResetInSec: weeklyWindow.resetInSec,
            updatedAt: now)
    }

    private static func parseWindow(_ dict: [String: Any], now: Date) -> (percent: Double, resetInSec: Int)? {
        var percent = self.doubleValue(from: dict, keys: self.percentKeys)

        if percent == nil {
            let used = self.doubleValue(from: dict, keys: ["used", "usage", "consumed", "count", "usedTokens"])
            let limit = self.doubleValue(from: dict, keys: ["limit", "total", "quota", "max", "cap", "tokenLimit"])
            if let used, let limit, limit > 0 {
                percent = (used / limit) * 100
            }
        }

        guard var resolvedPercent = percent else { return nil }
        if resolvedPercent <= 1.0, resolvedPercent >= 0 {
            resolvedPercent *= 100
        }
        resolvedPercent = max(0, min(100, resolvedPercent))

        var resetInSec = self.intValue(from: dict, keys: self.resetInKeys)
        if resetInSec == nil {
            let resetAtValue = self.value(from: dict, keys: self.resetAtKeys)
            if let resetAt = self.dateValue(from: resetAtValue) {
                resetInSec = max(0, Int(resetAt.timeIntervalSince(now)))
            }
        }

        let resolvedReset = max(0, resetInSec ?? 0)
        return (resolvedPercent, resolvedReset)
    }

    private static func doubleValue(from dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = self.doubleValue(from: dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func intValue(from dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = self.intValue(from: dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func value(from dict: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dict[key] {
                return value
            }
        }
        return nil
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
            if let parsed = self.makeISO8601Formatter().date(from: string) {
                return parsed
            }
        }
        return nil
    }

    private static func logParseSummary(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            let hint = if trimmed.hasPrefix("<") {
                "html"
            } else if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                "json"
            } else if trimmed.isEmpty {
                "empty"
            } else {
                "text"
            }
            Self.log.error("OpenCode response non-JSON: hint=\(hint) length=\(text.count)")
            return
        }
        self.logParseSummary(object: object)
    }

    private static func logParseSummary(object: Any) {
        let summary = self.summarizeJSON(object: object, depth: 0)
        guard !summary.isEmpty else { return }
        Self.log.error("OpenCode response summary: \(summary)")
    }

    private static func summarizeJSON(object: Any, depth: Int) -> String {
        if depth > 3 { return "" }
        if let dict = object as? [String: Any] {
            let keys = dict.keys.sorted()
            var parts: [String] = []
            for key in keys {
                let value = dict[key]
                let type = self.valueTypeDescription(value, depth: depth + 1)
                parts.append("\(key):\(type)")
            }
            return "{\(parts.joined(separator: ", "))}"
        }
        if let array = object as? [Any] {
            guard let first = array.first else { return "[]" }
            let type = self.valueTypeDescription(first, depth: depth + 1)
            return "[\(type)]"
        }
        return self.scalarTypeDescription(object)
    }

    private static func valueTypeDescription(_ value: Any?, depth: Int) -> String {
        guard let value else { return "null" }
        if let dict = value as? [String: Any] {
            return self.summarizeJSON(object: dict, depth: depth)
        }
        if let array = value as? [Any] {
            return self.summarizeJSON(object: array, depth: depth)
        }
        return self.scalarTypeDescription(value)
    }

    private static func scalarTypeDescription(_ value: Any) -> String {
        switch value {
        case is String: "string"
        case is Bool: "bool"
        case is Int, is Double, is NSNumber: "number"
        default: "value"
        }
    }
}
