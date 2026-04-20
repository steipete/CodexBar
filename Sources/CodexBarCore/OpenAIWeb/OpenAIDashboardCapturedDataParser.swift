import Foundation

extension OpenAIDashboardParser {
    public struct CapturedDashboardData: Equatable, Sendable {
        public let primaryLimit: RateWindow?
        public let secondaryLimit: RateWindow?
        public let codeReviewLimit: RateWindow?
        public let creditsRemaining: Double?
        public let creditEvents: [CreditEvent]
        public let usageBreakdown: [OpenAIDashboardDailyBreakdown]
        public let debugSummary: String?

        public init(
            primaryLimit: RateWindow?,
            secondaryLimit: RateWindow?,
            codeReviewLimit: RateWindow?,
            creditsRemaining: Double?,
            creditEvents: [CreditEvent],
            usageBreakdown: [OpenAIDashboardDailyBreakdown],
            debugSummary: String?)
        {
            self.primaryLimit = primaryLimit
            self.secondaryLimit = secondaryLimit
            self.codeReviewLimit = codeReviewLimit
            self.creditsRemaining = creditsRemaining
            self.creditEvents = creditEvents
            self.usageBreakdown = usageBreakdown
            self.debugSummary = debugSummary
        }

        public var hasDashboardSignal: Bool {
            self.primaryLimit != nil ||
                self.secondaryLimit != nil ||
                self.codeReviewLimit != nil ||
                self.creditsRemaining != nil ||
                !self.creditEvents.isEmpty ||
                !self.usageBreakdown.isEmpty
        }
    }

    public static func parseCapturedDashboardData(
        responsesJSON: String,
        now: Date = .init()) -> CapturedDashboardData?
    {
        guard let data = responsesJSON.data(using: .utf8), !data.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        guard let responses = json as? [[String: Any]], !responses.isEmpty else { return nil }

        let roots = responses.compactMap { response -> CapturedResponseRoot? in
            guard let payload = response["json"] else { return nil }
            return CapturedResponseRoot(url: response["url"] as? String, payload: payload)
        }
        guard !roots.isEmpty else { return nil }

        let creditDetails = self.bestCapturedCreditDetails(in: roots)
        let genericRateLimit = self.bestCapturedRateLimit(in: roots, preferCodeReview: false)
        let codeReviewRateLimit = self.bestCapturedRateLimit(in: roots, preferCodeReview: true)
        let creditHistory = self.bestCapturedCreditHistory(in: roots)
        let usageSeries = self.bestCapturedUsageSeries(in: roots)

        let creditsRemaining = creditDetails.flatMap(self.capturedCreditsRemaining(from:))
        let creditEvents = self.parseCapturedCreditEvents(creditHistory)
        let usageBreakdown = self.parseCapturedUsageBreakdown(usageSeries)
        let primaryLimit = genericRateLimit.flatMap { self.capturedRateWindow(from: $0.primaryWindow, now: now) }
        let secondaryLimit = genericRateLimit.flatMap { self.capturedRateWindow(from: $0.secondaryWindow, now: now) }
        let codeReviewLimit = codeReviewRateLimit.flatMap { self.capturedRateWindow(from: $0.primaryWindow, now: now) }

        let debugSummary = [
            "capturedResponses=\(roots.count)",
            "creditDetails=\(creditDetails == nil ? 0 : 1)",
            "rateLimit=\(genericRateLimit == nil ? 0 : 1)",
            "codeReviewRateLimit=\(codeReviewRateLimit == nil ? 0 : 1)",
            "creditHistory=\(creditHistory?.count ?? 0)",
            "usageSeriesDays=\(usageSeries?.count ?? 0)",
        ].joined(separator: " ")

        let result = CapturedDashboardData(
            primaryLimit: primaryLimit,
            secondaryLimit: secondaryLimit,
            codeReviewLimit: codeReviewLimit,
            creditsRemaining: creditsRemaining,
            creditEvents: creditEvents,
            usageBreakdown: usageBreakdown,
            debugSummary: debugSummary)
        return result.hasDashboardSignal ? result : nil
    }

    static func parseCreditsUsed(_ text: String) -> Double {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "credits", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned) ?? 0
    }

    // MARK: - Private

    private struct CapturedResponseRoot {
        let url: String?
        let payload: Any
    }

    private struct CapturedSearchMatch<T> {
        let value: T
        let path: [String]
        let url: String?
        let score: Int
    }

    private struct CapturedRateLimitContainer {
        let primaryWindow: [String: Any]?
        let secondaryWindow: [String: Any]?
    }

    private static func bestCapturedCreditDetails(in roots: [CapturedResponseRoot]) -> [String: Any]? {
        self.bestCapturedDictionary(in: roots) { dict, path, _ in
            guard self.isCapturedCreditDetails(dict) else { return nil }
            let pathText = self.capturedPathText(path)
            var score = 10
            if pathText.contains("creditdetails") { score += 30 }
            if pathText.contains("credit") { score += 15 }
            if pathText.contains("balance") { score += 10 }
            return score
        }?.value
    }

    private static func bestCapturedRateLimit(
        in roots: [CapturedResponseRoot],
        preferCodeReview: Bool)
        -> CapturedRateLimitContainer?
    {
        self.bestCapturedDictionary(in: roots) { dict, path, _ in
            guard self.isCapturedRateLimitContainer(dict) else { return nil }
            let pathText = self.capturedPathText(path)
            let isCodeReview = pathText.contains("review")
            if preferCodeReview != isCodeReview { return nil }
            var score = 10
            if pathText.contains("coderreviewratelimit") || pathText.contains("codereviewratelimit") {
                score += 40
            }
            if pathText.contains("ratelimit") { score += 25 }
            if pathText.contains("primary_window") || pathText.contains("secondary_window") {
                score += 5
            }
            return score
        }.map { match in
            CapturedRateLimitContainer(
                primaryWindow: match.value["primary_window"] as? [String: Any],
                secondaryWindow: match.value["secondary_window"] as? [String: Any])
        }
    }

    private static func bestCapturedCreditHistory(in roots: [CapturedResponseRoot]) -> [[String: Any]]? {
        self.bestCapturedArray(in: roots) { array, path, _ in
            let items = array.compactMap { $0 as? [String: Any] }
            guard items.count == array.count, self.isCapturedCreditHistory(items) else { return nil }
            let pathText = self.capturedPathText(path)
            var score = items.count
            if pathText.contains("credit") { score += 20 }
            if pathText.contains("history") { score += 15 }
            if pathText.contains("usage") { score += 10 }
            return score
        }?.value.compactMap { $0 as? [String: Any] }
    }

    private static func bestCapturedUsageSeries(in roots: [CapturedResponseRoot]) -> [[String: Any]]? {
        self.bestCapturedDictionary(in: roots) { dict, path, _ in
            guard let items = dict["data"] as? [[String: Any]], self.isCapturedUsageSeries(items) else { return nil }
            let pathText = self.capturedPathText(path)
            var score = items.count
            if pathText.contains("usage") { score += 20 }
            if pathText.contains("breakdown") { score += 10 }
            if pathText.contains("analytics") { score += 5 }
            return score
        }?.value["data"] as? [[String: Any]]
    }

    private static func bestCapturedDictionary(
        in roots: [CapturedResponseRoot],
        score: ([String: Any], [String], String?) -> Int?) -> CapturedSearchMatch<[String: Any]>?
    {
        var best: CapturedSearchMatch<[String: Any]>?
        for root in roots {
            var queue: [(value: Any, path: [String])] = [(root.payload, [])]
            var index = 0
            while index < queue.count {
                let next = queue[index]
                index += 1
                if let dict = next.value as? [String: Any] {
                    if let candidateScore = score(dict, next.path, root.url),
                       best == nil || candidateScore > best?.score ?? .min
                    {
                        best = CapturedSearchMatch(
                            value: dict,
                            path: next.path,
                            url: root.url,
                            score: candidateScore)
                    }
                    for (key, value) in dict {
                        queue.append((value, next.path + [key]))
                    }
                } else if let array = next.value as? [Any] {
                    for (arrayIndex, value) in array.enumerated() {
                        queue.append((value, next.path + ["[\(arrayIndex)]"]))
                    }
                }
            }
        }
        return best
    }

    private static func bestCapturedArray(
        in roots: [CapturedResponseRoot],
        score: ([Any], [String], String?) -> Int?) -> CapturedSearchMatch<[Any]>?
    {
        var best: CapturedSearchMatch<[Any]>?
        for root in roots {
            var queue: [(value: Any, path: [String])] = [(root.payload, [])]
            var index = 0
            while index < queue.count {
                let next = queue[index]
                index += 1
                if let dict = next.value as? [String: Any] {
                    for (key, value) in dict {
                        queue.append((value, next.path + [key]))
                    }
                } else if let array = next.value as? [Any] {
                    if let candidateScore = score(array, next.path, root.url),
                       best == nil || candidateScore > best?.score ?? .min
                    {
                        best = CapturedSearchMatch(
                            value: array,
                            path: next.path,
                            url: root.url,
                            score: candidateScore)
                    }
                    for (arrayIndex, value) in array.enumerated() {
                        queue.append((value, next.path + ["[\(arrayIndex)]"]))
                    }
                }
            }
        }
        return best
    }

    private static func isCapturedCreditDetails(_ dict: [String: Any]) -> Bool {
        guard dict["balance"] != nil else { return false }
        return dict["unlimited"] != nil || dict["approx_local_messages"] != nil || dict["approx_cloud_messages"] != nil
    }

    private static func isCapturedRateLimitContainer(_ dict: [String: Any]) -> Bool {
        dict["primary_window"] is [String: Any] || dict["secondary_window"] is [String: Any]
    }

    private static func isCapturedCreditHistory(_ items: [[String: Any]]) -> Bool {
        guard !items.isEmpty else { return false }
        let matching = items.reduce(into: 0) { partial, item in
            if item["date"] != nil,
               item["credit_amount"] != nil,
               item["product_surface"] != nil
            {
                partial += 1
            }
        }
        return matching == items.count
    }

    private static func isCapturedUsageSeries(_ items: [[String: Any]]) -> Bool {
        guard !items.isEmpty else { return false }
        return items.contains { item in
            item["date"] != nil && item["product_surface_usage_values"] is [String: Any]
        }
    }

    private static func capturedCreditsRemaining(from dict: [String: Any]) -> Double? {
        if let number = dict["balance"] as? NSNumber {
            return number.doubleValue
        }
        if let string = dict["balance"] as? String {
            return TextParsing.firstNumber(pattern: #"([0-9][0-9.,]*)"#, text: string)
        }
        return nil
    }

    private static func capturedRateWindow(from dict: [String: Any]?, now: Date) -> RateWindow? {
        guard let dict else { return nil }
        guard let remainingPercent = self.capturedDouble(dict["remaining_percent"]) else { return nil }
        let usedPercent = max(0, min(100, 100 - remainingPercent))
        let windowMinutes = self.capturedDouble(dict["limit_window_seconds"]).map { max(1, Int(round($0 / 60))) }
        let resetAfterSeconds =
            self.capturedDouble(dict["reset_after_seconds"]) ??
            self.capturedDouble(dict["reset_after_seconds_remaining"])
        let resetsAt = resetAfterSeconds.map { now.addingTimeInterval($0) }
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetsAt.map { UsageFormatter.resetDescription(from: $0) })
    }

    private static func parseCapturedCreditEvents(_ items: [[String: Any]]?) -> [CreditEvent] {
        guard let items else { return [] }
        return items.compactMap { item in
            guard let date = self.capturedDate(item["date"]) else { return nil }
            guard let creditsUsed = self.capturedDouble(item["credit_amount"]) else { return nil }
            let service = self.capturedProductSurfaceDisplayName(item["product_surface"] as? String)
            return CreditEvent(date: date, service: service, creditsUsed: creditsUsed)
        }
        .sorted { $0.date > $1.date }
    }

    private static func parseCapturedUsageBreakdown(_ items: [[String: Any]]?) -> [OpenAIDashboardDailyBreakdown] {
        guard let items else { return [] }
        let dayEntries = items.compactMap { item -> (String, [String: Any])? in
            guard let day = self.capturedDayKey(item["date"]) else { return nil }
            guard let values = item["product_surface_usage_values"] as? [String: Any] else { return nil }
            return (day, values)
        }

        guard !dayEntries.isEmpty else { return [] }

        return dayEntries
            .sorted { $0.0 > $1.0 }
            .prefix(30)
            .map { day, values in
                let services = values.compactMap { key, rawValue -> OpenAIDashboardServiceUsage? in
                    guard let credits = self.capturedDouble(rawValue), credits > 0 else { return nil }
                    return OpenAIDashboardServiceUsage(
                        service: self.capturedProductSurfaceDisplayName(key),
                        creditsUsed: credits)
                }
                .sorted { lhs, rhs in
                    if lhs.creditsUsed == rhs.creditsUsed { return lhs.service < rhs.service }
                    return lhs.creditsUsed > rhs.creditsUsed
                }
                let total = services.reduce(0) { $0 + $1.creditsUsed }
                return OpenAIDashboardDailyBreakdown(day: day, services: services, totalCreditsUsed: total)
            }
    }

    private static func capturedProductSurfaceDisplayName(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "desktop_app":
            "Desktop App"
        case "cli":
            "CLI"
        case "vscode":
            "Extension"
        case "web":
            "Cloud"
        case "github":
            "GitHub Turn"
        case "github_code_review":
            "GitHub Code Review"
        case "jetbrains":
            "JetBrains"
        case "slack":
            "Slack"
        case "linear":
            "Linear"
        case "sdk":
            "SDK"
        case "exec":
            "Exec"
        case "unknown", nil, "":
            "Other"
        default:
            self.normalizeCapturedIdentifier(raw ?? "")
        }
    }

    private static func capturedDate(_ raw: Any?) -> Date? {
        if let number = self.capturedDouble(raw) {
            return Date(timeIntervalSince1970: number > 4_000_000_000 ? number / 1000 : number)
        }
        guard let string = raw as? String else { return nil }
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd",
        ]
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            dateFormatter.dateFormat = format
            if let date = dateFormatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    static func capturedDayKey(_ raw: Any?, timeZone: TimeZone = .current) -> String? {
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count == 10, !trimmed.localizedCaseInsensitiveContains("t") {
                return trimmed
            }
        }
        guard let date = self.capturedDate(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func capturedDouble(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        guard let string = raw as? String else { return nil }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.replacingOccurrences(of: ",", with: "")
        if let value = Double(normalized) {
            return value
        }

        let numericPattern = #"^-?[0-9]+(?:\.[0-9]+)?$"#
        if normalized.range(of: numericPattern, options: .regularExpression) != nil {
            return Double(normalized)
        }
        return nil
    }

    private static func capturedPathText(_ path: [String]) -> String {
        path.joined(separator: ".").lowercased()
    }

    private static func normalizeCapturedIdentifier(_ raw: String) -> String {
        let words = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        return words.map { word in
            let value = String(word)
            return value.count <= 2 ? value.uppercased() : value.prefix(1).uppercased() + value.dropFirst()
        }.joined(separator: " ")
    }
}
