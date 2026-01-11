import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MiniMaxUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger("minimax-usage")
    private static let codingPlanURL = URL(
        string: "https://platform.minimax.io/user-center/payment/coding-plan?cycle_type=3")!
    private static let codingPlanRefererURL =
        URL(string: "https://platform.minimax.io/user-center/payment/coding-plan")!
    private static let codingPlanRemainsURL =
        URL(string: "https://platform.minimax.io/v1/api/openplatform/coding_plan/remains")!

    public static func fetchUsage(
        cookieHeader: String,
        authorizationToken: String? = nil,
        groupID: String? = nil,
        now: Date = Date()) async throws -> MiniMaxUsageSnapshot
    {
        guard let cookie = MiniMaxCookieHeader.normalized(from: cookieHeader) else {
            throw MiniMaxUsageError.invalidCredentials
        }

        do {
            return try await self.fetchCodingPlanHTML(
                cookie: cookie,
                authorizationToken: authorizationToken,
                now: now)
        } catch let error as MiniMaxUsageError {
            if case .parseFailed = error {
                Self.log.debug("MiniMax coding plan HTML parse failed, trying remains API")
                return try await self.fetchCodingPlanRemains(
                    cookie: cookie,
                    authorizationToken: authorizationToken,
                    groupID: groupID,
                    now: now)
            }
            throw error
        }
    }

    private static func fetchCodingPlanHTML(
        cookie: String,
        authorizationToken: String?,
        now: Date) async throws -> MiniMaxUsageSnapshot
    {
        var request = URLRequest(url: self.codingPlanURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let authorizationToken {
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        let acceptHeader = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        request.setValue(acceptHeader, forHTTPHeaderField: "accept")
        let userAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("https://platform.minimax.io", forHTTPHeaderField: "origin")
        request.setValue(self.codingPlanRefererURL.absoluteString, forHTTPHeaderField: "referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiniMaxUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("MiniMax returned \(httpResponse.statusCode): \(body)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("application/json")
        {
            return try MiniMaxUsageParser.parseCodingPlanRemains(data: data, now: now)
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        if html.contains("__NEXT_DATA__") {
            Self.log.debug("MiniMax coding plan HTML contains __NEXT_DATA__")
        }
        if self.looksSignedOut(html: html) {
            throw MiniMaxUsageError.invalidCredentials
        }
        return try MiniMaxUsageParser.parse(html: html, now: now)
    }

    private static func fetchCodingPlanRemains(
        cookie: String,
        authorizationToken: String?,
        groupID: String?,
        now: Date) async throws -> MiniMaxUsageSnapshot
    {
        let remainsURL = self.appendGroupID(groupID, to: self.codingPlanRemainsURL)
        var request = URLRequest(url: remainsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let authorizationToken {
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        let acceptHeader = "application/json, text/plain, */*"
        request.setValue(acceptHeader, forHTTPHeaderField: "accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
        let userAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("https://platform.minimax.io", forHTTPHeaderField: "origin")
        request.setValue(self.codingPlanRefererURL.absoluteString, forHTTPHeaderField: "referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiniMaxUsageError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Self.log.error("MiniMax returned \(httpResponse.statusCode): \(body)")
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }

        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("application/json")
        {
            if let json = self.decodeJSON(data: data) {
                self.logCodingPlanStatus(json: json)
                return try MiniMaxUsageParser.parseCodingPlanRemains(json: json, now: now)
            }
            return try MiniMaxUsageParser.parseCodingPlanRemains(data: data, now: now)
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        if self.looksSignedOut(html: html) {
            throw MiniMaxUsageError.invalidCredentials
        }
        return try MiniMaxUsageParser.parse(html: html, now: now)
    }

    private static func appendGroupID(_ groupID: String?, to url: URL) -> URL {
        guard let groupID, !groupID.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "GroupId", value: groupID))
        components.queryItems = queryItems
        return components.url ?? url
    }

    private static func decodeJSON(data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else { return nil }
        return dict
    }

    private static func logCodingPlanStatus(json: [String: Any]) {
        guard let base = json["base_resp"] as? [String: Any] else { return }
        let status: Int? = switch base["status_code"] {
        case let number as Int:
            number
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
        guard let status else { return }
        let message = (base["status_msg"] as? String) ?? ""
        if !message.isEmpty {
            Self.log.debug("MiniMax coding plan status \(status): \(message)")
        } else {
            Self.log.debug("MiniMax coding plan status \(status)")
        }
    }

    private static func looksSignedOut(html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("sign in") || lower.contains("log in") || lower.contains("登录") || lower.contains("登入")
    }
}

enum MiniMaxUsageParser {
    static func parseCodingPlanRemains(data: Data, now: Date = Date()) throws -> MiniMaxUsageSnapshot {
        let json = try self.decodeJSON(data: data)
        return try self.parseCodingPlanRemains(json: json, now: now)
    }

    static func parse(html: String, now: Date = Date()) throws -> MiniMaxUsageSnapshot {
        if let snapshot = self.parseNextData(html: html, now: now) {
            return snapshot
        }
        let text = self.stripHTML(html)

        let planName = self.parsePlanName(html: html, text: text)
        let available = self.parseAvailableUsage(text: text)
        let usedPercent = self.parseUsedPercent(text: text)
        let resetsAt = self.parseResetsAt(text: text, now: now)

        if planName == nil, available == nil, usedPercent == nil {
            throw MiniMaxUsageError.parseFailed("Missing coding plan data.")
        }

        return MiniMaxUsageSnapshot(
            planName: planName,
            availablePrompts: available?.prompts,
            windowMinutes: available?.windowMinutes,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            updatedAt: now)
    }

    static func parseCodingPlanRemains(json: [String: Any], now: Date = Date()) throws -> MiniMaxUsageSnapshot {
        if let base = json["base_resp"] as? [String: Any],
           let status = self.intValue(base["status_code"]),
           status != 0
        {
            let message = (base["status_msg"] as? String) ?? "status_code \(status)"
            let lower = message.lowercased()
            if status == 1004 || lower.contains("cookie") || lower.contains("log in") || lower.contains("login") {
                throw MiniMaxUsageError.invalidCredentials
            }
            throw MiniMaxUsageError.apiError(message)
        }

        let root = (json["data"] as? [String: Any]) ?? json
        let modelRemains = root["model_remains"] as? [[String: Any]] ?? []
        guard let first = modelRemains.first else {
            throw MiniMaxUsageError.parseFailed("Missing coding plan data.")
        }

        let total = self.intValue(first["current_interval_total_count"])
        let remaining = self.intValue(first["current_interval_usage_count"])
        let usedPercent = self.usedPercent(total: total, remaining: remaining)

        let windowMinutes = self.windowMinutes(
            start: self.dateFromEpoch(first["start_time"]),
            end: self.dateFromEpoch(first["end_time"]))

        let resetsAt = self.resetsAt(
            end: self.dateFromEpoch(first["end_time"]),
            remains: self.intValue(first["remains_time"]),
            now: now)

        let planName = self.parsePlanName(root: root)

        if planName == nil, total == nil, usedPercent == nil {
            throw MiniMaxUsageError.parseFailed("Missing coding plan data.")
        }

        return MiniMaxUsageSnapshot(
            planName: planName,
            availablePrompts: total,
            windowMinutes: windowMinutes,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            updatedAt: now)
    }

    private static func decodeJSON(data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        if let dict = object as? [String: Any] {
            return dict
        }
        throw MiniMaxUsageError.parseFailed("Invalid coding plan response.")
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            number
        case let number as Int64:
            Int(number)
        case let number as Double:
            Int(number)
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func usedPercent(total: Int?, remaining: Int?) -> Double? {
        guard let total, total > 0, let remaining else { return nil }
        let used: Int = if remaining > total {
            min(remaining, total)
        } else {
            max(0, total - remaining)
        }
        let percent = Double(used) / Double(total) * 100
        return min(100, max(0, percent))
    }

    private static func dateFromEpoch(_ value: Any?) -> Date? {
        guard let raw = self.intValue(value) else { return nil }
        if raw > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(raw) / 1000)
        }
        if raw > 1_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(raw))
        }
        return nil
    }

    private static func windowMinutes(start: Date?, end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        return minutes > 0 ? minutes : nil
    }

    private static func resetsAt(end: Date?, remains: Int?, now: Date) -> Date? {
        if let end, end > now {
            return end
        }
        guard let remains, remains > 0 else { return nil }
        let seconds: TimeInterval = remains > 1_000_000 ? TimeInterval(remains) / 1000 : TimeInterval(remains)
        return now.addingTimeInterval(seconds)
    }

    private static func parsePlanName(root: [String: Any]) -> String? {
        let directKeys = [
            "current_subscribe_title",
            "plan_name",
            "combo_title",
            "current_plan_title",
        ]
        for key in directKeys {
            if let value = root[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        if let card = root["current_combo_card"] as? [String: Any],
           let title = card["title"] as? String
        {
            return title
        }
        return nil
    }

    private static func parsePlanName(html: String, text: String) -> String? {
        let candidates = [
            self.extractFirst(pattern: #"(?i)"planName"\s*:\s*"([^"]+)""#, text: html),
            self.extractFirst(pattern: #"(?i)"plan"\s*:\s*"([^"]+)""#, text: html),
            self.extractFirst(pattern: #"(?i)"packageName"\s*:\s*"([^"]+)""#, text: html),
            self.extractFirst(pattern: #"(?i)Coding\s*Plan\s*([A-Za-z0-9][A-Za-z0-9\s._-]{0,32})"#, text: text),
        ].compactMap(\.self)

        for candidate in candidates {
            let cleaned = UsageFormatter.cleanPlanName(candidate)
            let trimmed = cleaned
                .replacingOccurrences(
                    of: #"(?i)\s+available\s+usage.*$"#,
                    with: "",
                    options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func parseNextData(html: String, now: Date) -> MiniMaxUsageSnapshot? {
        guard let data = self.nextDataJSONData(fromHTML: html) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        guard let payload = self.findCodingPlanPayload(in: object) else { return nil }
        return try? self.parseCodingPlanRemains(json: payload, now: now)
    }

    private static func findCodingPlanPayload(in object: Any) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            if dict["model_remains"] != nil {
                return dict
            }
            for value in dict.values {
                if let match = self.findCodingPlanPayload(in: value) {
                    return match
                }
            }
            return nil
        }

        if let array = object as? [Any] {
            for value in array {
                if let match = self.findCodingPlanPayload(in: value) {
                    return match
                }
            }
        }
        return nil
    }

    private static let nextDataNeedle = Data("id=\"__NEXT_DATA__\"".utf8)
    private static let scriptCloseNeedle = Data("</script>".utf8)

    private static func nextDataJSONData(fromHTML html: String) -> Data? {
        let data = Data(html.utf8)
        guard let idRange = data.range(of: self.nextDataNeedle) else { return nil }
        guard let openTagEnd = data[idRange.upperBound...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
        let contentStart = data.index(after: openTagEnd)
        guard let closeRange = data.range(
            of: self.scriptCloseNeedle,
            options: [],
            in: contentStart..<data.endIndex)
        else { return nil }
        let rawData = data[contentStart..<closeRange.lowerBound]
        let trimmed = self.trimASCIIWhitespace(Data(rawData))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimASCIIWhitespace(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var start = data.startIndex
        var end = data.endIndex

        while start < end, self.isASCIIWhitespace(data[start]) {
            start = data.index(after: start)
        }
        while end > start {
            let prev = data.index(before: end)
            if self.isASCIIWhitespace(data[prev]) {
                end = prev
            } else {
                break
            }
        }
        return data.subdata(in: start..<end)
    }

    private static func isASCIIWhitespace(_ value: UInt8) -> Bool {
        switch value {
        case 9, 10, 13, 32:
            true
        default:
            false
        }
    }

    private static func parseAvailableUsage(text: String) -> (prompts: Int, windowMinutes: Int)? {
        let pattern =
            #"(?i)available\s+usage[:\s]*([0-9][0-9,]*)\s*prompts?\s*/\s*"# +
            #"([0-9]+(?:\.[0-9]+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|days?|d)"#
        guard let match = self.extractMatch(pattern: pattern, text: text), match.count >= 3 else { return nil }
        let promptsRaw = match[0]
        let durationRaw = match[1]
        let unitRaw = match[2]

        let prompts = Int(promptsRaw.replacingOccurrences(of: ",", with: "")) ?? 0
        guard prompts > 0 else { return nil }

        guard let duration = Double(durationRaw) else { return nil }
        let windowMinutes = self.minutes(from: duration, unit: unitRaw)
        guard windowMinutes > 0 else { return nil }
        return (prompts, windowMinutes)
    }

    private static func parseUsedPercent(text: String) -> Double? {
        let patterns = [
            #"(?i)([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*used"#,
            #"(?i)used\s*([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#,
        ]
        for pattern in patterns {
            if let raw = self.extractFirst(pattern: pattern, text: text),
               let value = Double(raw),
               value >= 0,
               value <= 100
            {
                return value
            }
        }
        return nil
    }

    private static func parseResetsAt(text: String, now: Date) -> Date? {
        if let match = self.extractMatch(
            pattern: #"(?i)resets?\s+in\s+([0-9]+)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d)"#,
            text: text),
            match.count >= 2,
            let value = Double(match[0])
        {
            let unit = match[1]
            let seconds = self.seconds(from: value, unit: unit)
            return now.addingTimeInterval(seconds)
        }

        if let match = self.extractMatch(
            pattern: #"(?i)resets?\s+at\s+([0-9]{1,2}:[0-9]{2})(?:\s*\(([^)]+)\))?"#,
            text: text),
            match.count >= 1
        {
            let timeText = match[0]
            let tzText = match.count > 1 ? match[1] : nil
            return self.dateForTime(timeText, timeZoneHint: tzText, now: now)
        }

        return nil
    }

    private static func dateForTime(_ time: String, timeZoneHint: String?, now: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if let tzHint = timeZoneHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tzHint.isEmpty
        {
            formatter.timeZone = TimeZone(identifier: tzHint)
        }
        formatter.locale = Locale(identifier: "en_US_POSIX")

        guard let timeOnly = formatter.date(from: time) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone ?? .current

        let nowComponents = calendar.dateComponents([.year, .month, .day], from: now)
        var targetComponents = calendar.dateComponents([.hour, .minute], from: timeOnly)
        targetComponents.year = nowComponents.year
        targetComponents.month = nowComponents.month
        targetComponents.day = nowComponents.day
        guard var candidate = calendar.date(from: targetComponents) else { return nil }

        if candidate < now {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private static func minutes(from value: Double, unit: String) -> Int {
        let lower = unit.lowercased()
        if lower.hasPrefix("d") { return Int((value * 24 * 60).rounded()) }
        if lower.hasPrefix("h") { return Int((value * 60).rounded()) }
        if lower.hasPrefix("m") { return Int(value.rounded()) }
        if lower.hasPrefix("s") { return max(1, Int((value / 60).rounded())) }
        return 0
    }

    private static func seconds(from value: Double, unit: String) -> TimeInterval {
        let lower = unit.lowercased()
        if lower.hasPrefix("d") { return value * 24 * 60 * 60 }
        if lower.hasPrefix("h") { return value * 60 * 60 }
        if lower.hasPrefix("m") { return value * 60 }
        return value
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractFirst(pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractMatch(pattern: String, text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { idx in
            guard let captureRange = Range(match.range(at: idx), in: text) else { return nil }
            return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

public enum MiniMaxUsageError: LocalizedError, Sendable, Equatable {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "MiniMax session cookie is invalid or expired."
        case let .networkError(message):
            "MiniMax network error: \(message)"
        case let .apiError(message):
            "MiniMax API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse MiniMax coding plan: \(message)"
        }
    }
}
