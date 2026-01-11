import Foundation

enum AmpUsageParser {
    static func parse(html: String, now: Date = Date()) throws -> AmpUsageSnapshot {
        guard let usage = self.parseFreeTierUsage(html) else {
            if self.looksSignedOut(html) {
                throw AmpUsageError.notLoggedIn
            }
            throw AmpUsageError.parseFailed("Missing Amp Free usage data.")
        }

        return AmpUsageSnapshot(
            freeQuota: usage.quota,
            freeUsed: usage.used,
            hourlyReplenishment: usage.hourlyReplenishment,
            windowHours: usage.windowHours,
            updatedAt: now)
    }

    private struct FreeTierUsage: Sendable {
        let quota: Double
        let used: Double
        let hourlyReplenishment: Double
        let windowHours: Double?
    }

    private static func parseFreeTierUsage(_ html: String) -> FreeTierUsage? {
        let tokens = ["freeTierUsage", "getFreeTierUsage"]
        for token in tokens {
            if let object = self.extractObject(named: token, in: html),
               let usage = self.parseFreeTierUsageObject(object)
            {
                return usage
            }
        }
        return nil
    }

    private static func parseFreeTierUsageObject(_ object: String) -> FreeTierUsage? {
        guard let quota = self.number(for: "quota", in: object),
              let used = self.number(for: "used", in: object),
              let hourly = self.number(for: "hourlyReplenishment", in: object)
        else { return nil }

        let windowHours = self.number(for: "windowHours", in: object)
        return FreeTierUsage(
            quota: quota,
            used: used,
            hourlyReplenishment: hourly,
            windowHours: windowHours)
    }

    private static func extractObject(named token: String, in text: String) -> String? {
        guard let tokenRange = text.range(of: token) else { return nil }
        guard let braceIndex = text[tokenRange.upperBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var isEscaped = false
        var index = braceIndex

        while index < text.endIndex {
            let char = text[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[braceIndex...index])
                    }
                }
            }
            index = text.index(after: index)
        }

        return nil
    }

    private static func number(for key: String, in text: String) -> Double? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: key))\\b\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[valueRange])
    }

    private static func looksSignedOut(_ html: String) -> Bool {
        let lower = html.lowercased()
        if lower.contains("sign in") || lower.contains("log in") || lower.contains("login") {
            return true
        }
        if lower.contains("/login") || lower.contains("ampcode.com/login") {
            return true
        }
        return false
    }
}
