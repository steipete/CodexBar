import Foundation

public enum CodeRabbitUsageParser {
    public static func parse(
        usageText: String,
        authText: String? = nil,
        now: Date = Date()) throws -> CodeRabbitUsageSnapshot
    {
        let cleanUsage = TextParsing.stripANSICodes(usageText)

        if self.looksSignedOut(cleanUsage) {
            throw CodeRabbitUsageError.notLoggedIn
        }

        let orgPattern = #"(?im)^\s*Organization\s*:\s*(.+?)\s*$"#
        let usageBillingPattern = #"(?im)^\s*Usage billing\s*:\s*(.+?)\s*$"#
        let userPattern = #"(?im)^\s*User\s*:\s*(.+?)\s*$"#
        let reviewsPattern = #"(?im)^\s*Your reviews\s*:\s*([0-9]+)\s*$"#
        let resetPattern = #"(?im)^\s*Period resets\s*:\s*(.+?)\s*$"#

        let organization = self.firstCapture(in: cleanUsage, pattern: orgPattern)
        let usageBilling = self.firstCapture(in: cleanUsage, pattern: usageBillingPattern)
        let user = self.firstCapture(in: cleanUsage, pattern: userPattern)
        let reviewsCount = self.firstCapture(in: cleanUsage, pattern: reviewsPattern).flatMap(Int.init)
        let periodResetsRaw = self.firstCapture(in: cleanUsage, pattern: resetPattern)
        let periodResets = periodResetsRaw.flatMap(self.parseDate)

        var accountEmail: String?
        var plan: String?
        var authOrg: String?
        var authUser: String?

        if let authText, !authText.isEmpty {
            let cleanAuth = TextParsing.stripANSICodes(authText)
            let accountPattern = #"(?im)^\s*Account\s*:\s*([^\s(]+)(?:\s+\(([^)]+)\))?\s*$"#
            let planPattern = #"(?im)^\s*Plan\s*:\s*(.+?)\s*$"#

            if let accountCaptures = self.captures(in: cleanAuth, pattern: accountPattern) {
                if accountCaptures.count > 0 {
                    authUser = self.nonEmpty(accountCaptures[0])
                }
                if accountCaptures.count > 1 {
                    accountEmail = self.nonEmpty(accountCaptures[1])
                }
            }

            plan = self.firstCapture(in: cleanAuth, pattern: planPattern)
            authOrg = self.firstCapture(in: cleanAuth, pattern: orgPattern)
        }

        guard organization != nil || user != nil || reviewsCount != nil || periodResetsRaw != nil || plan != nil else {
            throw CodeRabbitUsageError.parseFailed("Could not extract usage or billing information from CodeRabbit CLI output.")
        }

        return CodeRabbitUsageSnapshot(
            organization: organization ?? authOrg,
            user: user ?? authUser,
            accountEmail: accountEmail,
            plan: plan,
            reviewsCount: reviewsCount,
            usageBilling: usageBilling,
            periodResets: periodResets,
            periodResetsRaw: periodResetsRaw,
            updatedAt: now)
    }

    private static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("not authenticated") ||
            lower.contains("please log in") ||
            lower.contains("auth login") ||
            lower.contains("authentication required") ||
            lower.contains("unauthorized") ||
            lower.contains("no session found") ||
            lower.contains("401 unauthorized")
    }

    private static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let iso = ISO8601DateFormatter().date(from: trimmed) {
            return iso
        }

        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnly.dateFormat = "yyyy-MM-dd"
        if let date = dateOnly.date(from: trimmed) {
            return date
        }

        let withTime = DateFormatter()
        withTime.locale = Locale(identifier: "en_US_POSIX")
        withTime.timeZone = TimeZone(secondsFromGMT: 0)
        withTime.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return withTime.date(from: trimmed)
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        self.captures(in: text, pattern: pattern)?.first
    }

    private static func captures(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound,
                  let r = Range(captureRange, in: text)
            else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
