import Foundation

public enum DisplayFormat {
    public static func updateTimestamp(_ date: Date, now: Date = .init()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    public static func resetDescription(from date: Date, now: Date = .init()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return "tomorrow, \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    public static func resetLine(for window: RateWindow) -> String? {
        if let date = window.resetsAt {
            return "Resets \(self.resetDescription(from: date))"
        }
        if let description = window.resetDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !description.isEmpty
        {
            return description.lowercased().hasPrefix("resets") ? description : "Resets \(description)"
        }
        return nil
    }

    public static func credits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let formatted = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "\(formatted) left"
    }

    public static func percentRemaining(_ value: Double) -> String {
        "\(Int(value.rounded()))% left"
    }

    public static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    public static func tokenCount(_ value: Int) -> String {
        let absValue = abs(value)
        let sign = value < 0 ? "-" : ""
        let units: [(threshold: Int, divisor: Double, suffix: String)] = [
            (1_000_000_000, 1_000_000_000, "B"),
            (1_000_000, 1_000_000, "M"),
            (1000, 1000, "K"),
        ]
        for unit in units where absValue >= unit.threshold {
            let scaled = Double(absValue) / unit.divisor
            let formatted = scaled >= 10 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
            return "\(sign)\(formatted.replacingOccurrences(of: ".0", with: ""))\(unit.suffix)"
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func relativeDate(_ date: Date, now: Date = .init()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 {
            return "just now"
        }
        if seconds < 3600 {
            return "\(max(1, seconds / 60))m ago"
        }
        if seconds < 24 * 3600 {
            return "\(max(1, seconds / 3600))h ago"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
