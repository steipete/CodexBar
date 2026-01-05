import Foundation

public enum OpenAIDashboardParser {
    /// Extracts the signed-in email from the embedded `client-bootstrap` JSON payload, if present.
    ///
    /// The Codex usage dashboard currently ships a JSON blob in:
    /// `<script type="application/json" id="client-bootstrap">…</script>`.
    /// WebKit `document.body.innerText` often does not include the email, so we parse it from HTML.
    public static func parseSignedInEmailFromClientBootstrap(html: String) -> String? {
        guard let data = self.clientBootstrapJSONData(fromHTML: html) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }

        // Fast path: common structure.
        if let dict = json as? [String: Any] {
            if let session = dict["session"] as? [String: Any],
               let user = session["user"] as? [String: Any],
               let email = user["email"] as? String,
               email.contains("@")
            {
                return email.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let user = dict["user"] as? [String: Any],
               let email = user["email"] as? String,
               email.contains("@")
            {
                return email.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Fallback: BFS scan for an email key/value.
        var queue: [Any] = [json]
        var seen = 0
        while !queue.isEmpty, seen < 4000 {
            let cur = queue.removeFirst()
            seen += 1
            if let dict = cur as? [String: Any] {
                for (k, v) in dict {
                    if k.lowercased() == "email", let email = v as? String, email.contains("@") {
                        return email.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    queue.append(v)
                }
            } else if let arr = cur as? [Any] {
                queue.append(contentsOf: arr)
            }
        }
        return nil
    }

    /// Extracts the auth status from `client-bootstrap`, if present.
    /// Expected values include `logged_in` and `logged_out`.
    public static func parseAuthStatusFromClientBootstrap(html: String) -> String? {
        guard let data = self.clientBootstrapJSONData(fromHTML: html) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        guard let dict = json as? [String: Any] else { return nil }
        if let authStatus = dict["authStatus"] as? String, !authStatus.isEmpty {
            return authStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    public static func parseCodeReviewRemainingPercent(bodyText: String) -> Double? {
        let cleaned = bodyText.replacingOccurrences(of: "\r", with: "\n")
        for regex in self.codeReviewRegexes {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            guard let match = regex.firstMatch(in: cleaned, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: cleaned)
            else { continue }
            if let val = Double(cleaned[r]) { return min(100, max(0, val)) }
        }
        return nil
    }

    public static func parseCreditsRemaining(bodyText: String) -> Double? {
        let cleaned = bodyText.replacingOccurrences(of: "\r", with: "\n")
        let patterns = [
            #"credits\s*remaining[^0-9]*([0-9][0-9.,]*)"#,
            #"remaining\s*credits[^0-9]*([0-9][0-9.,]*)"#,
            #"credit\s*balance[^0-9]*([0-9][0-9.,]*)"#,
        ]
        for pattern in patterns {
            if let val = TextParsing.firstNumber(pattern: pattern, text: cleaned) { return val }
        }
        return nil
    }

    public static func parseRateLimits(
        bodyText: String,
        now: Date = .init()) -> (primary: RateWindow?, secondary: RateWindow?)
    {
        let cleaned = bodyText.replacingOccurrences(of: "\r", with: "\n")
        let lines = cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let primary = self.parseRateWindow(
            lines: lines,
            match: self.isFiveHourLimitLine,
            windowMinutes: 5 * 60,
            now: now)
        let secondary = self.parseRateWindow(
            lines: lines,
            match: self.isWeeklyLimitLine,
            windowMinutes: 7 * 24 * 60,
            now: now)
        return (primary, secondary)
    }

    public static func parsePlanFromHTML(html: String) -> String? {
        if let data = self.clientBootstrapJSONData(fromHTML: html),
           let plan = self.findPlan(in: data)
        {
            return plan
        }
        if let data = self.nextDataJSONData(fromHTML: html),
           let plan = self.findPlan(in: data)
        {
            return plan
        }
        return nil
    }

    public static func parseCreditEvents(rows: [[String]]) -> [CreditEvent] {
        let formatter = self.creditDateFormatter()

        return rows.compactMap { row in
            guard row.count >= 3 else { return nil }
            let dateString = row[0]
            let service = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let amountString = row[2]
            guard let date = formatter.date(from: dateString) else { return nil }
            let creditsUsed = Self.parseCreditsUsed(amountString)
            return CreditEvent(date: date, service: service, creditsUsed: creditsUsed)
        }
        .sorted { $0.date > $1.date }
    }

    private static func parseCreditsUsed(_ text: String) -> Double {
        let cleaned = text
            .replacingOccurrences(of: "credits", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TextParsing.parseLocalizedNumber(cleaned) ?? 0
    }

    // MARK: - Private

    private static let codeReviewRegexes: [NSRegularExpression] = {
        let patterns = [
            #"Code\s*review[^0-9%]*([0-9]{1,3})%\s*remaining"#,
            #"Core\s*review[^0-9%]*([0-9]{1,3})%\s*remaining"#,
        ]
        return patterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }()

    private static let creditDateFormatterKey = "OpenAIDashboardParser.creditDateFormatter"
    private static let clientBootstrapNeedle = Data("id=\"client-bootstrap\"".utf8)
    private static let nextDataNeedle = Data("id=\"__NEXT_DATA__\"".utf8)
    private static let scriptCloseNeedle = Data("</script>".utf8)

    private static func creditDateFormatter() -> DateFormatter {
        let threadDict = Thread.current.threadDictionary
        if let cached = threadDict[self.creditDateFormatterKey] as? DateFormatter {
            return cached
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        threadDict[self.creditDateFormatterKey] = formatter
        return formatter
    }

    private static func clientBootstrapJSONData(fromHTML html: String) -> Data? {
        let data = Data(html.utf8)
        guard let idRange = data.range(of: self.clientBootstrapNeedle) else { return nil }

        guard let openTagEnd = data[idRange.upperBound...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
        let contentStart = data.index(after: openTagEnd)
        guard let closeRange = data.range(
            of: self.scriptCloseNeedle,
            options: [],
            in: contentStart..<data.endIndex)
        else {
            return nil
        }
        let rawData = data[contentStart..<closeRange.lowerBound]
        let trimmed = self.trimASCIIWhitespace(Data(rawData))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nextDataJSONData(fromHTML html: String) -> Data? {
        let data = Data(html.utf8)
        guard let idRange = data.range(of: self.nextDataNeedle) else { return nil }

        guard let openTagEnd = data[idRange.upperBound...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
        let contentStart = data.index(after: openTagEnd)
        guard let closeRange = data.range(
            of: self.scriptCloseNeedle,
            options: [],
            in: contentStart..<data.endIndex)
        else {
            return nil
        }
        let rawData = data[contentStart..<closeRange.lowerBound]
        let trimmed = self.trimASCIIWhitespace(Data(rawData))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimASCIIWhitespace(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var start = data.startIndex
        var end = data.endIndex

        while start < end, data[start].isASCIIWhitespace {
            start = data.index(after: start)
        }
        while end > start {
            let prev = data.index(before: end)
            if data[prev].isASCIIWhitespace {
                end = prev
            } else {
                break
            }
        }
        return data.subdata(in: start..<end)
    }

    private static func parseRateWindow(
        lines: [String],
        match: (String) -> Bool,
        windowMinutes: Int,
        now: Date) -> RateWindow?
    {
        guard let idx = lines.firstIndex(where: match) else { return nil }
        let end = min(lines.count - 1, idx + 5)
        let windowLines = Array(lines[idx...end])

        var percentValue: Double?
        var isRemaining = true
        for line in windowLines {
            if let percent = self.parsePercent(from: line) {
                percentValue = percent.value
                isRemaining = percent.isRemaining
                break
            }
        }

        guard let percentValue else { return nil }
        let usedPercent = isRemaining ? max(0, min(100, 100 - percentValue)) : max(0, min(100, percentValue))

        let resetLine = windowLines.first { $0.localizedCaseInsensitiveContains("reset") }
        let resetDescription = resetLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resetsAt = resetLine.flatMap { self.parseResetDate(from: $0, now: now) }
        let fallbackDescription = resetsAt.map { UsageFormatter.resetDescription(from: $0) }

        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription ?? fallbackDescription)
    }

    private static func parsePercent(from line: String) -> (value: Double, isRemaining: Bool)? {
        guard let percent = TextParsing.firstNumber(pattern: #"([0-9]{1,3})\s*%"#, text: line) else { return nil }
        let lower = line.lowercased()
        let isRemaining = lower.contains("remaining") || lower.contains("left")
        let isUsed = lower.contains("used") || lower.contains("spent") || lower.contains("consumed")
        if isUsed { return (percent, false) }
        if isRemaining { return (percent, true) }
        return (percent, true)
    }

    private static func isFiveHourLimitLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("5h") { return true }
        if lower.contains("5-hour") { return true }
        if lower.contains("5 hour") { return true }
        return false
    }

    private static func isWeeklyLimitLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("weekly") { return true }
        if lower.contains("7-day") { return true }
        if lower.contains("7 day") { return true }
        if lower.contains("7d") { return true }
        return false
    }

    private static func parseResetDate(from line: String, now: Date) -> Date? {
        var raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        raw = raw.replacingOccurrences(of: #"(?i)^resets?:?\s*"#, with: "", options: .regularExpression)
        raw = raw.replacingOccurrences(of: " at ", with: " ", options: .caseInsensitive)
        raw = raw.replacingOccurrences(of: " on ", with: " ", options: .caseInsensitive)
        raw = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let calendar = Calendar(identifier: .gregorian)
        let monthDayFormatter = DateFormatter()
        monthDayFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthDayFormatter.timeZone = TimeZone.current
        monthDayFormatter.dateFormat = "MMM d"

        var candidate = raw
        let lower = candidate.lowercased()
        var usedRelativeDay = false

        if lower.contains("today") {
            usedRelativeDay = true
            let dateText = monthDayFormatter.string(from: now)
            candidate = candidate.replacingOccurrences(of: "today", with: dateText, options: .caseInsensitive)
        } else if lower.contains("tomorrow") {
            usedRelativeDay = true
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
                let dateText = monthDayFormatter.string(from: tomorrow)
                candidate = candidate.replacingOccurrences(of: "tomorrow", with: dateText, options: .caseInsensitive)
            }
        }

        if let weekdayMatch = self.weekdayMatch(in: candidate) {
            usedRelativeDay = true
            let target = self.nextWeekdayDate(weekday: weekdayMatch.weekday, now: now, calendar: calendar)
            let dateText = monthDayFormatter.string(from: target)
            candidate = candidate.replacingOccurrences(
                of: weekdayMatch.matched,
                with: dateText,
                options: .caseInsensitive)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.defaultDate = now

        let formats = [
            "MMM d h:mma",
            "MMM d, h:mma",
            "MMM d h:mm a",
            "MMM d, h:mm a",
            "MMM d HH:mm",
            "MMM d, HH:mm",
            "MMM d",
            "M/d h:mma",
            "M/d h:mm a",
            "M/d/yyyy h:mm a",
            "M/d/yy h:mm a",
            "M/d",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd h:mm a",
            "yyyy-MM-dd",
        ]

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: candidate) {
                if usedRelativeDay, date < now {
                    if lower.contains("today"),
                       let bumped = calendar.date(byAdding: .day, value: 1, to: date)
                    {
                        return bumped
                    }
                    if let bumped = calendar.date(byAdding: .day, value: 7, to: date) {
                        return bumped
                    }
                }
                return date
            }
        }
        return nil
    }

    private struct WeekdayMatch {
        let matched: String
        let weekday: Int
    }

    private static func weekdayMatch(in text: String) -> WeekdayMatch? {
        let pattern = #"\b(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)(day)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range(at: 0), in: text)
        else { return nil }
        let matched = String(text[r])
        let lower = matched.lowercased()
        let weekday = switch lower.prefix(3) {
        case "mon": 2
        case "tue": 3
        case "wed": 4
        case "thu": 5
        case "fri": 6
        case "sat": 7
        default: 1
        }
        return WeekdayMatch(matched: matched, weekday: weekday)
    }

    private static func nextWeekdayDate(weekday: Int, now: Date, calendar: Calendar) -> Date {
        let currentWeekday = calendar.component(.weekday, from: now)
        var delta = weekday - currentWeekday
        if delta < 0 { delta += 7 }
        guard let next = calendar.date(byAdding: .day, value: delta, to: calendar.startOfDay(for: now)) else {
            return now
        }
        return next
    }

    private static func findPlan(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return self.findPlan(in: json)
    }

    private static func findPlan(in json: Any) -> String? {
        var queue: [Any] = [json]
        var seen = 0
        while !queue.isEmpty, seen < 6000 {
            let cur = queue.removeFirst()
            seen += 1
            if let dict = cur as? [String: Any] {
                for (k, v) in dict {
                    if let plan = self.planCandidate(forKey: k, value: v) { return plan }
                    queue.append(v)
                }
            } else if let arr = cur as? [Any] {
                queue.append(contentsOf: arr)
            }
        }
        return nil
    }

    private static func planCandidate(forKey key: String, value: Any) -> String? {
        guard self.isPlanKey(key) else { return nil }
        if let str = value as? String {
            return self.normalizePlanValue(str)
        }
        if let dict = value as? [String: Any] {
            if let name = dict["name"] as? String, let plan = self.normalizePlanValue(name) { return plan }
            if let display = dict["displayName"] as? String, let plan = self.normalizePlanValue(display) { return plan }
            if let tier = dict["tier"] as? String, let plan = self.normalizePlanValue(tier) { return plan }
        }
        return nil
    }

    private static func isPlanKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("plan") || lower.contains("tier") || lower.contains("subscription")
    }

    private static func normalizePlanValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let allowed = [
            "free",
            "plus",
            "pro",
            "team",
            "enterprise",
            "business",
            "edu",
            "education",
            "gov",
            "premium",
            "essential",
        ]
        guard allowed.contains(where: { lower.contains($0) }) else { return nil }
        return UsageFormatter.cleanPlanName(trimmed)
    }
}

extension UInt8 {
    fileprivate var isASCIIWhitespace: Bool {
        switch self {
        case 9, 10, 13, 32: true
        default: false
        }
    }
}
