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
        let text = TextParsing.stripANSICodes(displayText).replacingOccurrences(of: "**", with: "")
        let identityPattern = #"(?im)^\s*Signed in as\s+([^\s(]+)(?:\s+\(([^\r\n)]+)\))?\s*$"#
        let identity = self.captures(in: text, pattern: identityPattern)
        if identity == nil, self.looksSignedOut(text) {
            throw AmpUsageError.notLoggedIn
        }

        let amountPattern = #"([0-9][0-9,]*(?:\.[0-9]+)?)"#
        let freePattern = #"(?im)^\s*Amp Free:\s*\$?"# + amountPattern +
            #"\s*/\s*\$?"# + amountPattern +
            #"\s+remaining(?:\s*\(replenishes\s*\+\$?"# + amountPattern + #"\s*/\s*hour\))?"#
        let freePercentPattern = #"(?im)^\s*Amp Free:\s*"# + amountPattern +
            #"\s*%\s+remaining(?:\s+today)?(?:\s*(\(resets\s+daily\)))?"#
        let subscriptionSuffix = #"\s*"# + amountPattern +
            #"\s*%\s+other\s+usage\s+and\s+"# + amountPattern +
            #"\s*%\s+orb\s+usage\s+remaining\s*-\s*resets\s+upon\s+renewal\s+in\s+"# +
            #"([0-9][0-9,]*)\s+(days?|months?)(?:\s+-\s+https?://\S+)?\s*$"#
        let subscriptionPatterns = [
            #"(?im)^\s*Subscription\s+(.+?):"# + subscriptionSuffix,
            #"(?im)^\s*Amp\s+(.+?)\s+Subscription:"# + subscriptionSuffix,
        ]
        let tierPattern = #"(?im)^\s*Amp\s+([^\r\n]+?)\s+Tier:\s*agent\s+usage\s+\$"# + amountPattern +
            #"\s+of\s+\$"# + amountPattern + #"\s+remaining\b([^\r\n]*?)resets\s+upon\s+renewal\s+in\s+"# +
            #"([0-9][0-9,]*)\s+(days?|months?)\b"#
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
                windowHours: windowHours,
                resetDescription: nil)
        }()
        let freePercentUsage: FreeTierUsage? = {
            guard let free = self.captures(in: text, pattern: freePercentPattern),
                  let remaining = self.number(from: free[0])
            else { return nil }
            let clampedRemaining = min(100, max(0, remaining))
            return FreeTierUsage(
                quota: 100,
                used: 100 - clampedRemaining,
                hourlyReplenishment: 0,
                windowHours: 24,
                resetDescription: self.nonEmpty(free[1]).map { _ in "resets daily" })
        }()
        let resolvedFreeUsage = freeUsage ?? freePercentUsage
        let subscriptionUsage: AmpSubscriptionUsage? = {
            // Agent dollars are authoritative; the displayed percentage is rounded. Orb text is independent.
            if let tier = self.captures(in: text, pattern: tierPattern),
               let remaining = self.number(from: tier[1]),
               let limit = self.number(from: tier[2]), limit > 0
            {
                let period = self.tierPeriod(in: tier[3])
                let renewalText = tier[4].replacingOccurrences(of: ",", with: "")
                let renewalValue = Int(renewalText)
                guard let resetsAt = period?.end
                    ?? renewalValue.flatMap({ self.subscriptionResetDate(value: $0, unit: tier[5], now: now) })
                else { return nil }
                let displayedRenewal = renewalValue.map(String.init) ?? renewalText
                let orbPattern = #"(?i)\borb\s+usage\s+"# +
                    amountPattern + #"h\s+of\s+"# + amountPattern + #"h\s+a1\.small\s+orb\s+hours\s+remaining\b"#
                let orb = self.captures(in: tier[3], pattern: orbPattern)
                let orbRemaining = orb.flatMap { self.number(from: $0[0]) }
                let orbLimit = orb.flatMap { self.number(from: $0[1]) }.flatMap { $0 > 0 ? $0 : nil }
                let orbUsedPercent: Double? = if let orbRemaining, let orbLimit {
                    min(100, max(0, (orbLimit - orbRemaining) / orbLimit * 100))
                } else {
                    nil
                }
                return AmpSubscriptionUsage(
                    plan: tier[0],
                    otherUsedPercent: min(100, max(0, (limit - remaining) / limit * 100)),
                    orbUsedPercent: orbUsedPercent,
                    resetsAt: resetsAt,
                    resetDescription: "renews in \(displayedRenewal) \(tier[5].lowercased())",
                    agentRemaining: remaining,
                    agentLimit: limit,
                    periodStart: period?.start,
                    orbHoursRemaining: orbLimit == nil ? nil : orbRemaining,
                    orbHoursLimit: orbLimit)
            }
            guard let subscription = subscriptionPatterns.lazy.compactMap({ pattern in
                self.captures(in: text, pattern: pattern)
            }).first,
                subscription.count == 5,
                let plan = self.nonEmpty(subscription[0]),
                let otherRemaining = self.number(from: subscription[1]),
                let orbRemaining = self.number(from: subscription[2]),
                let renewalValue = Int(subscription[3].replacingOccurrences(of: ",", with: "")),
                let resetsAt = self.subscriptionResetDate(
                    value: renewalValue,
                    unit: subscription[4],
                    now: now)
            else { return nil }
            let unit = subscription[4].lowercased()
            let singularUnit = unit.hasPrefix("month") ? "month" : "day"
            let resetDescription = "renews in \(renewalValue) \(singularUnit)\(renewalValue == 1 ? "" : "s")"
            return AmpSubscriptionUsage(
                plan: plan,
                otherUsedPercent: 100 - min(100, max(0, otherRemaining)),
                orbUsedPercent: 100 - min(100, max(0, orbRemaining)),
                resetsAt: resetsAt,
                resetDescription: resetDescription)
        }()
        guard resolvedFreeUsage != nil || subscriptionUsage != nil || individualCredits != nil ||
            !workspaceBalances.isEmpty
        else {
            throw AmpUsageError.parseFailed("Missing Amp usage data.")
        }

        return AmpUsageSnapshot(
            freeQuota: resolvedFreeUsage?.quota,
            freeUsed: resolvedFreeUsage?.used,
            hourlyReplenishment: resolvedFreeUsage?.hourlyReplenishment,
            windowHours: resolvedFreeUsage?.windowHours,
            individualCredits: individualCredits,
            workspaceBalances: workspaceBalances,
            accountEmail: self.nonEmpty(identity?[0]),
            accountOrganization: self.nonEmpty(identity?[1]),
            updatedAt: now,
            freeResetDescription: resolvedFreeUsage?.resetDescription,
            subscription: subscriptionUsage)
    }

    private static func tierPeriod(in text: String) -> (start: Date, end: Date)? {
        let pattern = #"\bperiod\s+(\d{4}-\d{2}-\d{2})\s+to\s+(\d{4}-\d{2}-\d{2})\b"#
        guard let dates = self.captures(in: text, pattern: pattern) else { return nil }
        // CLI dates have day precision, not a renewal timestamp. Use UTC day boundaries consistently;
        // never anchor the billing cycle to a rounded countdown that moves on every refresh.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let start = formatter.date(from: dates[0]), let end = formatter.date(from: dates[1]),
              formatter.string(from: start) == dates[0], formatter.string(from: end) == dates[1],
              end > start
        else { return nil }
        return (start, end)
    }

    private static func subscriptionResetDate(value: Int, unit: String, now: Date) -> Date? {
        let isMonth = unit.lowercased().hasPrefix("month")
        let secondsPerUnit = (isMonth ? 31 : 1) * 24 * 60 * 60
        guard value <= Int.max / secondsPerUnit else { return nil }
        if isMonth {
            return Calendar(identifier: .gregorian).date(byAdding: .month, value: value, to: now)
        }
        return now.addingTimeInterval(TimeInterval(value) * 24 * 60 * 60)
    }

    private struct FreeTierUsage {
        let quota: Double
        let used: Double
        let hourlyReplenishment: Double
        let windowHours: Double?
        let resetDescription: String?
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
            windowHours: windowHours,
            resetDescription: nil)
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
