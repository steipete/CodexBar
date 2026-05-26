import Foundation

public enum ResetTimeDisplayStyle: String, Codable, Sendable {
    case countdown
    case absolute
}

public enum UsageFormatter {
    private final class BundleToken {}

    private static let localizationLock = NSLock()
    private nonisolated(unsafe) static var localizationProvider: (@Sendable (String) -> String)?
    private nonisolated(unsafe) static var localeProvider: (@Sendable () -> Locale)?

    public static func setLocalizationProvider(_ provider: @escaping @Sendable (String) -> String) {
        self.localizationLock.lock()
        self.localizationProvider = provider
        self.localizationLock.unlock()
    }

    public static func clearLocalizationProvider() {
        self.localizationLock.lock()
        self.localizationProvider = nil
        self.localizationLock.unlock()
    }

    public static func setLocaleProvider(_ provider: @escaping @Sendable () -> Locale) {
        self.localizationLock.lock()
        self.localeProvider = provider
        self.localizationLock.unlock()
    }

    public static func clearLocaleProvider() {
        self.localizationLock.lock()
        self.localeProvider = nil
        self.localizationLock.unlock()
    }

    private static func currentLocale() -> Locale {
        self.localizationLock.lock()
        let provider = self.localeProvider
        self.localizationLock.unlock()
        return provider?() ?? Locale(identifier: "en_US_POSIX")
    }

    private static func localized(_ key: String) -> String {
        self.localizationLock.lock()
        let provider = self.localizationProvider
        self.localizationLock.unlock()
        if let provider {
            return provider(key)
        }
        let coreBundle = Bundle(for: BundleToken.self)
        let coreValue = NSLocalizedString(key, tableName: "Localizable", bundle: coreBundle, value: key, comment: "")
        if coreValue != key { return coreValue }

        let mainValue = NSLocalizedString(key, tableName: "Localizable", bundle: .main, value: key, comment: "")
        if mainValue != key { return mainValue }

        switch key {
        case "usage_percent_suffix_left": return "left"
        case "usage_percent_suffix_used": return "used"
        default: return key
        }
    }

    private static func localized(_ key: String, _ args: CVarArg...) -> String {
        let format = self.localized(key)
        return String(format: format, locale: self.currentLocale(), arguments: args)
    }

    public static func usageLine(remaining: Double, used: Double, showUsed: Bool) -> String {
        let percent = showUsed ? used : remaining
        let clamped = min(100, max(0, percent))
        let suffix = showUsed
            ? self.localized("usage_percent_suffix_used")
            : self.localized("usage_percent_suffix_left")
        return String(format: "%.0f%% %@", clamped, suffix)
    }

    public static func resetCountdownDescription(from date: Date, now: Date = .init()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 1 { return "now" }

        let totalMinutes = max(1, Int(ceil(seconds / 60.0)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 { return "in \(days)d \(hours)h" }
            return "in \(days)d"
        }
        if hours > 0 {
            if minutes > 0 { return "in \(hours)h \(minutes)m" }
            return "in \(hours)h"
        }
        return "in \(totalMinutes)m"
    }

    public static func resetDescription(from date: Date, now: Date = .init()) -> String {
        // Human-friendly phrasing: today / tomorrow / date+time.
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute().locale(self.currentLocale()))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return "tomorrow, \(date.formatted(.dateTime.hour().minute().locale(self.currentLocale())))"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(self.currentLocale()))
    }

    public static func resetLine(
        for window: RateWindow,
        style: ResetTimeDisplayStyle,
        now: Date = .init()) -> String?
    {
        if let date = window.resetsAt {
            if style == .countdown {
                let countdown = self.resetCountdownDescription(from: date, now: now)
                if countdown == "now" {
                    return self.localized("Resets now")
                }
                if countdown.hasPrefix("in ") {
                    return self.localized("Resets in %@", String(countdown.dropFirst(3)))
                }
                return self.localized("Resets %@", countdown)
            }
            let text = self.resetDescription(from: date, now: now)
            return self.localized("Resets %@", text)
        }

        if let desc = window.resetDescription {
            let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.lowercased().hasPrefix("resets in ") {
                return self.localized("Resets in %@", String(trimmed.dropFirst("Resets in ".count)))
            }
            if trimmed.lowercased().hasPrefix("resets ") {
                return self.localized("Resets %@", String(trimmed.dropFirst("Resets ".count)))
            }
            return self.localized("Resets %@", trimmed)
        }
        return nil
    }

    public static func updatedString(from date: Date, now: Date = .init()) -> String {
        let delta = now.timeIntervalSince(date)
        if abs(delta) < 60 {
            return self.localized("Updated just now")
        }
        if let hours = Calendar.current.dateComponents([.hour], from: date, to: now).hour, hours < 24 {
            #if os(macOS)
            let rel = RelativeDateTimeFormatter()
            rel.locale = self.currentLocale()
            rel.unitsStyle = .abbreviated
            return self.localized("Updated %@", rel.localizedString(for: date, relativeTo: now))
            #else
            let seconds = max(0, Int(now.timeIntervalSince(date)))
            if seconds < 3600 {
                let minutes = max(1, seconds / 60)
                return self.localized("Updated %@m ago", String(minutes))
            }
            let wholeHours = max(1, seconds / 3600)
            return self.localized("Updated %@h ago", String(wholeHours))
            #endif
        } else {
            return self.localized(
                "Updated %@",
                date.formatted(.dateTime.hour().minute().locale(self.currentLocale())))
        }
    }

    public static func creditsString(from value: Double) -> String {
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.maximumFractionDigits = 2
        // Use explicit locale for consistent formatting on all systems
        number.locale = Locale(identifier: "en_US_POSIX")
        let formatted = number.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return self.localized("%@ left", formatted)
    }

    public static func kiroCreditNumber(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.005 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.2f", value)
    }

    /// Formats a USD value with proper negative handling and thousand separators.
    /// Uses Swift's modern FormatStyle API (iOS 15+/macOS 12+) for robust, locale-aware formatting.
    public static func usdString(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    public static let costEstimateHint = "Estimated from local logs · may differ from your bill"

    public static func costEstimateHint(provider: UsageProvider) -> String {
        switch provider {
        case .claude:
            "Estimated from local Claude logs at API rates; token totals include cache read/write tokens " +
                "and may differ from Claude Code /status."
        default:
            self.costEstimateHint
        }
    }

    /// Formats a currency value with the specified currency code.
    /// Uses FormatStyle with explicit en_US locale to ensure consistent formatting
    /// regardless of the user's system locale (e.g., pt-BR users see $54.72 not US$ 54,72).
    public static func currencyString(_ value: Double, currencyCode: String) -> String {
        value.formatted(.currency(code: currencyCode).locale(Locale(identifier: "en_US")))
    }

    public static func tokenCountString(_ value: Int) -> String {
        let absValue = abs(value)
        let sign = value < 0 ? "-" : ""

        let units: [(threshold: Int, divisor: Double, suffix: String)] = [
            (1_000_000_000, 1_000_000_000, "B"),
            (1_000_000, 1_000_000, "M"),
            (1000, 1000, "K"),
        ]

        for unit in units where absValue >= unit.threshold {
            let scaled = Double(absValue) / unit.divisor
            let formatted: String
            if scaled >= 10 {
                formatted = String(format: "%.0f", scaled)
            } else {
                var s = String(format: "%.1f", scaled)
                if s.hasSuffix(".0") { s.removeLast(2) }
                formatted = s
            }
            return "\(sign)\(formatted)\(unit.suffix)"
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func byteCountString(_ bytes: Int64) -> String {
        let sign = bytes < 0 ? "-" : ""
        let absBytes = Double(Swift.abs(bytes))
        let units: [(threshold: Double, divisor: Double, suffix: String)] = [
            (1024 * 1024 * 1024, 1024 * 1024 * 1024, "GB"),
            (1024 * 1024, 1024 * 1024, "MB"),
            (1024, 1024, "KB"),
        ]

        for unit in units where absBytes >= unit.threshold {
            let scaled = absBytes / unit.divisor
            let format = scaled >= 10 || scaled.rounded(.towardZero) == scaled ? "%.0f" : "%.1f"
            let formatted = String(format: format, scaled)
            return "\(sign)\(formatted) \(unit.suffix)"
        }

        return "\(bytes) B"
    }

    public static func creditEventSummary(_ event: CreditEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.maximumFractionDigits = 2
        let credits = number.string(from: NSNumber(value: event.creditsUsed)) ?? "0"
        return "\(formatter.string(from: event.date)) · \(event.service) · \(credits) credits"
    }

    public static func creditEventCompact(_ event: CreditEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.maximumFractionDigits = 2
        let credits = number.string(from: NSNumber(value: event.creditsUsed)) ?? "0"
        return "\(formatter.string(from: event.date)) — \(event.service): \(credits)"
    }

    public static func creditShort(_ value: Double) -> String {
        if value >= 1000 {
            let k = value / 1000
            return String(format: "%.1fk", k)
        }
        return String(format: "%.0f", value)
    }

    public static func truncatedSingleLine(_ text: String, max: Int = 80) -> String {
        let single = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard single.count > max else { return single }
        let idx = single.index(single.startIndex, offsetBy: max)
        return "\(single[..<idx])…"
    }

    public static func modelDisplayName(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return raw }

        let patterns = [
            #"(?:-|\s)\d{8}$"#,
            #"(?:-|\s)\d{4}-\d{2}-\d{2}$"#,
            #"\s\d{4}\s\d{4}$"#,
        ]

        for pattern in patterns {
            if let range = cleaned.range(of: pattern, options: .regularExpression) {
                cleaned.removeSubrange(range)
                break
            }
        }

        if let trailing = cleaned.range(of: #"[ \t-]+$"#, options: .regularExpression) {
            cleaned.removeSubrange(trailing)
        }

        return cleaned.isEmpty ? raw : cleaned
    }

    public static func modelCostDetail(
        _ model: String,
        costUSD: Double?,
        totalTokens: Int? = nil,
        currencyCode: String = "USD") -> String?
    {
        let costDetail: String? = if let label = CostUsagePricing.codexDisplayLabel(model: model) {
            label
        } else if let costUSD {
            self.currencyString(costUSD, currencyCode: currencyCode)
        } else {
            nil
        }

        let tokenDetail = totalTokens.map(self.tokenCountString)
        let parts = [costDetail, tokenDetail].compactMap(\.self)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Cleans a provider plan string: strip ANSI/bracket noise, drop boilerplate words, collapse whitespace, and
    /// ensure a leading capital if the result starts lowercase.
    public static func cleanPlanName(_ text: String) -> String {
        let stripped = TextParsing.stripANSICodes(text)
        let withoutCodes = stripped.replacingOccurrences(
            of: #"^\s*(?:\[\d{1,3}m\s*)+"#,
            with: "",
            options: [.regularExpression])
        let withoutBoilerplate = withoutCodes.replacingOccurrences(
            of: #"(?i)\b(claude|codex|account|plan)\b"#,
            with: "",
            options: [.regularExpression])
        var cleaned = withoutBoilerplate
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.lowercased() == "oauth" {
            return "Ollama"
        }
        // Capitalize first letter only if lowercase, preserving acronyms like "AI"
        if let first = cleaned.first, first.isLowercase {
            return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        }
        return cleaned
    }
}
