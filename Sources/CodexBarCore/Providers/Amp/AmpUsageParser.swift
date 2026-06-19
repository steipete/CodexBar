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

    static func parse(displayText: String, now: Date = Date()) throws -> AmpUsageSnapshot {
        let text = TextParsing.stripANSICodes(displayText)
        let identityPattern = #"(?im)^\s*Signed in as\s+([^\s(]+)(?:\s+\(([^\r\n)]+)\))?\s*$"#
        let identity = self.captures(in: text, pattern: identityPattern)
        if identity == nil, self.looksSignedOut(text) {
            throw AmpUsageError.notLoggedIn
        }

        let amountPattern = #"([0-9][0-9,]*(?:\.[0-9]+)?)"#
        let freePattern = #"(?im)^\s*Amp Free:\s*\$?"# + amountPattern +
            #"\s*/\s*\$?"# + amountPattern +
            #"\s+remaining(?:\s*\(replenishes\s*\+\$?"# + amountPattern + #"\s*/\s*hour\))?"#
        let creditsPattern = #"(?im)^\s*Individual credits:\s*\$?"# + amountPattern + #"\s+remaining"#
        let individualCredits = self.captures(in: text, pattern: creditsPattern)?.first
            .flatMap(self.number(from:))
        let workspacePattern = #"(?im)^\s*Workspace\s+(.+?):\s*\$?"# + amountPattern + #"\s+remaining"#
        let workspaceBalances: [AmpWorkspaceBalance] = self.allCaptures(
            in: text,
            pattern: workspacePattern).compactMap { captures -> AmpWorkspaceBalance? in
            guard captures.count == 2,
                  let name = self.nonEmpty(captures[0]),
                  let remaining = self.number(from: captures[1])
            else { return nil }
            return AmpWorkspaceBalance(name: name, remaining: remaining)
        }
        let freeUsage: FreeTierUsage? = {
            guard let free = self.captures(in: text, pattern: freePattern),
                  let remaining = self.number(from: free[0]),
                  let quota = self.number(from: free[1])
            else { return nil }
            let hourlyReplenishment = self.number(from: free[2]) ?? 0
            let windowHours = hourlyReplenishment > 0
                ? max(1, (quota / hourlyReplenishment).rounded())
                : nil
            return FreeTierUsage(
                quota: quota,
                used: max(0, quota - remaining),
                hourlyReplenishment: hourlyReplenishment,
                windowHours: windowHours)
        }()
        guard freeUsage != nil || individualCredits != nil || !workspaceBalances.isEmpty else {
            throw AmpUsageError.parseFailed("Missing Amp usage data.")
        }

        return AmpUsageSnapshot(
            freeQuota: freeUsage?.quota,
            freeUsed: freeUsage?.used,
            hourlyReplenishment: freeUsage?.hourlyReplenishment,
            windowHours: freeUsage?.windowHours,
            individualCredits: individualCredits,
            workspaceBalances: workspaceBalances,
            accountEmail: self.nonEmpty(identity?[0]),
            accountOrganization: self.nonEmpty(identity?[1]),
            updatedAt: now)
    }

    private struct FreeTierUsage {
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

    private static func captures(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }

        return self.captures(in: text, match: match)
    }

    private static func allCaptures(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).map { match in
            self.captures(in: text, match: match)
        }
    }

    private static func captures(in text: String, match: NSTextCheckingResult) -> [String] {
        (1..<match.numberOfRanges).map { index in
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound,
                  let range = Range(captureRange, in: text)
            else { return "" }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func number(from text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
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
