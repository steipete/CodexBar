import Foundation

enum OllamaUsageParser {
    static func parse(html: String, now: Date = Date()) throws -> OllamaUsageSnapshot {
        let plan = self.parsePlanName(html)
        let email = self.parseAccountEmail(html)
        let session = self.parseUsageBlock(label: "Session usage", html: html)
        let weekly = self.parseUsageBlock(label: "Weekly usage", html: html)

        if session == nil && weekly == nil {
            if self.looksSignedOut(html) {
                throw OllamaUsageError.notLoggedIn
            }
            throw OllamaUsageError.parseFailed("Missing Ollama usage data.")
        }

        return OllamaUsageSnapshot(
            planName: plan,
            accountEmail: email,
            sessionUsedPercent: session?.usedPercent,
            weeklyUsedPercent: weekly?.usedPercent,
            sessionResetsAt: session?.resetsAt,
            weeklyResetsAt: weekly?.resetsAt,
            updatedAt: now)
    }

    private struct UsageBlock: Sendable {
        let usedPercent: Double
        let resetsAt: Date?
    }

    private static func parsePlanName(_ html: String) -> String? {
        let pattern = #"Cloud Usage\s*</span>\s*<span[^>]*>([^<]+)</span>"#
        guard let raw = self.firstCapture(in: html, pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        let window = String(tail.prefix(800))

        guard let usedPercent = self.parsePercent(in: window) else { return nil }
        let resetsAt = self.parseISODate(in: window)
        return UsageBlock(usedPercent: usedPercent, resetsAt: resetsAt)
    }

    private static func parsePercent(in text: String) -> Double? {
        let usedPattern = #"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#
        if let raw = self.firstCapture(in: text, pattern: usedPattern, options: [.caseInsensitive]) {
            return Double(raw)
        }
        let widthPattern = #"width:\s*([0-9]+(?:\.[0-9]+)?)%"#
        if let raw = self.firstCapture(in: text, pattern: widthPattern, options: [.caseInsensitive]) {
            return Double(raw)
        }
        return nil
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
        if lower.contains("sign in") || lower.contains("log in") || lower.contains("login") {
            return true
        }
        if lower.contains("/login") || lower.contains("/signin") {
            return true
        }
        return false
    }
}
