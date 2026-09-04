import Foundation

enum OllamaUsageParser {
    // Current settings use monthly credits; retain legacy usage labels for older pages.
    private static let monthlyUsageLabel = "Monthly usage"
    private static let legacyPrimaryUsageLabels = ["Session usage", "Hourly usage"]
    private static let primaryUsageLabels = [monthlyUsageLabel] + legacyPrimaryUsageLabels
    private static let usageLabels = primaryUsageLabels + ["Weekly usage"]

    enum ParseFailure: Equatable {
        case notLoggedIn
        case missingUsageData
    }

    enum ClassifiedParseResult {
        case success(OllamaUsageSnapshot)
        case failure(ParseFailure)
    }

    static func parse(html: String, now: Date = Date()) throws -> OllamaUsageSnapshot {
        switch self.parseClassified(html: html, now: now) {
        case let .success(snapshot):
            return snapshot
        case .failure(.notLoggedIn):
            throw OllamaUsageError.notLoggedIn
        case .failure(.missingUsageData):
            throw OllamaUsageError.parseFailed("Missing Ollama usage data.")
        }
    }

    static func parseClassified(html: String, now: Date = Date()) -> ClassifiedParseResult {
        let plan = self.parsePlanName(html)
        let email = self.parseAccountEmail(html)
        let monthly = self.parseUsageBlock(label: self.monthlyUsageLabel, html: html)
        let session = self.parseUsageBlock(labels: Self.legacyPrimaryUsageLabels, html: html)
        let weekly = self.parseUsageBlock(label: "Weekly usage", html: html)

        if monthly == nil, session == nil, weekly == nil {
            if self.looksSignedOut(html) {
                return .failure(.notLoggedIn)
            }
            return .failure(.missingUsageData)
        }

        return .success(OllamaUsageSnapshot(
            planName: plan,
            accountEmail: email,
            monthlyUsedPercent: monthly?.usedPercent,
            monthlyResetsAt: monthly?.resetsAt,
            sessionUsedPercent: session?.usedPercent,
            weeklyUsedPercent: weekly?.usedPercent,
            sessionResetsAt: session?.resetsAt,
            weeklyResetsAt: weekly?.resetsAt,
            sessionWindowMinutes: session?.windowMinutes,
            updatedAt: now))
    }

    private struct UsageBlock {
        let usedPercent: Double
        let resetsAt: Date?
        let windowMinutes: Int?
    }

    private static func parsePlanName(_ html: String) -> String? {
        // The new heading is "Included usage <plan>"; its closing tag renders as
        // "</span\n>", so the pattern intentionally omits the final ">".
        let patterns = [
            #"Included usage\s*</span>\s*<span[^>]*>([^<]+)</span"#,
            #"Cloud Usage\s*</span>\s*<span[^>]*>([^<]+)</span>"#,
        ]
        for pattern in patterns {
            guard let raw = self.firstCapture(in: html, pattern: pattern, options: [.dotMatchesLineSeparators])
            else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func parseAccountEmail(_ html: String) -> String? {
        let pattern = #"id=\"header-email\"[^>]*>([^<]+)<"#
        guard let raw = self.firstCapture(in: html, pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else { return nil }
        return trimmed
    }

    private static func parseUsageBlock(label: String, html: String) -> UsageBlock? {
        guard let labelRange = html.range(of: label) else { return nil }
        let tail = String(html[labelRange.upperBound...])
        let window = self.usageBlockWindow(after: label, in: tail)

        guard let usedPercent = self.parsePercent(in: window) else { return nil }
        let resetsAt = self.parseISODate(in: window)
        let windowMinutes: Int? = switch label {
        case self.monthlyUsageLabel:
            // Monthly windows carry the 30-day sentinel duration; pace resolves the real
            // calendar month from the reset date via the resetWindowPace rule.
            ProviderPaceCapability.monthlyWindowSentinelMinutes
        case "Session usage":
            5 * 60
        default:
            nil
        }
        return UsageBlock(
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            windowMinutes: windowMinutes)
    }

    private static func parseUsageBlock(labels: [String], html: String) -> UsageBlock? {
        for label in labels {
            if let parsed = self.parseUsageBlock(label: label, html: html) {
                return parsed
            }
        }
        return nil
    }

    private static func usageBlockWindow(after label: String, in tail: String) -> String {
        let maxLength = 4000
        let boundary = self.usageLabels
            .filter { $0 != label }
            .compactMap { tail.range(of: $0)?.lowerBound }
            .min()
        let bounded = boundary.map { String(tail[..<$0]) } ?? String(tail.prefix(maxLength))
        return String(bounded.prefix(maxLength))
    }

    private static func parsePercent(in text: String) -> Double? {
        let usedPattern = #"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#
        if let raw = self.firstCapture(in: text, pattern: usedPattern, options: [.caseInsensitive]) {
            return Double(raw)
        }
        if let dollarPercent = self.parseDollarUsedPercent(in: text) {
            return dollarPercent
        }
        let widthPattern = #"width:\s*([0-9]+(?:\.[0-9]+)?)%"#
        if let raw = self.firstCapture(in: text, pattern: widthPattern, options: [.caseInsensitive]) {
            return Double(raw)
        }
        return nil
    }

    /// Convert included dollar credits to quota utilization, not a spend estimate.
    private static func parseDollarUsedPercent(in text: String) -> Double? {
        let amount = #"((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)"#
        let pattern = #"\$\#(amount)\s+of\s+\$\#(amount)\s+used"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 2,
              let usedRange = Range(match.range(at: 1), in: text),
              let limitRange = Range(match.range(at: 2), in: text)
        else { return nil }
        guard let used = Double(text[usedRange].replacingOccurrences(of: ",", with: "")),
              let limit = Double(text[limitRange].replacingOccurrences(of: ",", with: "")),
              used.isFinite, limit.isFinite, limit > 0
        else { return nil }
        let percent = used / limit * 100
        return percent.isFinite ? percent : nil
    }

    private static func parseISODate(in text: String) -> Date? {
        let pattern = #"data-time=\"([^\"]+)\""#
        guard let raw = self.firstCapture(in: text, pattern: pattern, options: []) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: raw)
    }

    private static func firstCapture(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options) -> String?
    {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return Self.performMatch(regex: regex, text: text)
    }

    private static func performMatch(
        regex: NSRegularExpression,
        text: String) -> String?
    {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captureRange])
    }

    private static func looksSignedOut(_ html: String) -> Bool {
        let lower = html.lowercased()
        let hasSignInHeading = lower.contains("sign in to ollama") || lower.contains("log in to ollama")
        let hasAuthRoute = lower.contains("/api/auth/signin") || lower.contains("/auth/signin")
        let hasLoginRoute = lower.contains("action=\"/login\"")
            || lower.contains("action='/login'")
            || lower.contains("href=\"/login\"")
            || lower.contains("href='/login'")
            || lower.contains("action=\"/signin\"")
            || lower.contains("action='/signin'")
            || lower.contains("href=\"/signin\"")
            || lower.contains("href='/signin'")
        let hasPasswordField = lower.contains("type=\"password\"")
            || lower.contains("type='password'")
            || lower.contains("name=\"password\"")
            || lower.contains("name='password'")
        let hasEmailField = lower.contains("type=\"email\"")
            || lower.contains("type='email'")
            || lower.contains("name=\"email\"")
            || lower.contains("name='email'")
        let hasAuthForm = lower.contains("<form")
        let hasAuthEndpoint = hasAuthRoute || hasLoginRoute

        if hasSignInHeading, hasAuthForm, hasEmailField || hasPasswordField || hasAuthEndpoint {
            return true
        }
        if hasAuthForm, hasAuthEndpoint {
            return true
        }
        if hasAuthForm, hasPasswordField, hasEmailField {
            return true
        }
        return false
    }
}
