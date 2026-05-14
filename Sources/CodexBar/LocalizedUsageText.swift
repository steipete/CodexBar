import CodexBarCore
import Foundation

enum LocalizedUsageText {
    static func usageLine(remaining: Double, used: Double, showUsed: Bool) -> String {
        let percent = showUsed ? used : remaining
        let clamped = min(100, max(0, percent))
        let suffix = showUsed ? L("used") : L("left")
        return String(format: "%.0f%% %@", clamped, suffix)
    }

    static func resetLine(
        for window: RateWindow,
        style: ResetTimeDisplayStyle,
        now: Date = .init()) -> String?
    {
        if let date = window.resetsAt {
            let text = style == .countdown
                ? self.resetCountdownDescription(from: date, now: now)
                : self.resetDescription(from: date, now: now)
            return String(format: L("Resets %@"), text)
        }

        if let desc = window.resetDescription {
            let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.lowercased().hasPrefix("resets") {
                let suffix = trimmed.dropFirst("resets".count).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !suffix.isEmpty else { return L("Resets") }
                return String(format: L("Resets %@"), suffix)
            }
            return String(format: L("Resets %@"), trimmed)
        }
        return nil
    }

    static func updatedString(from date: Date, now: Date = .init()) -> String {
        let delta = now.timeIntervalSince(date)
        if abs(delta) < 60 {
            return L("Updated just now")
        }

        if let hours = Calendar.current.dateComponents([.hour], from: date, to: now).hour, hours < 24 {
            let rel = RelativeDateTimeFormatter()
            rel.locale = codexBarLocalizationLocale()
            rel.unitsStyle = .abbreviated
            return String(format: L("Updated %@"), rel.localizedString(for: date, relativeTo: now))
        }

        return String(format: L("Updated %@"), self.formattedTime(date))
    }

    static func creditsString(from value: Double) -> String {
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.maximumFractionDigits = 2
        number.locale = codexBarLocalizationLocale()
        let formatted = number.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return String(format: L("%@ left"), formatted)
    }

    static func creditEventSummary(_ event: CreditEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.locale = codexBarLocalizationLocale()

        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.maximumFractionDigits = 2
        number.locale = codexBarLocalizationLocale()

        let credits = number.string(from: NSNumber(value: event.creditsUsed)) ?? "0"
        return String(
            format: L("%1$@ · %2$@ · %3$@ credits"),
            formatter.string(from: event.date),
            event.service,
            credits)
    }

    static func resetCountdownDescription(from date: Date, now: Date = .init()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 1 { return L("now") }

        let totalMinutes = max(1, Int(ceil(seconds / 60.0)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 { return String(format: L("in %1$d d %2$d h"), days, hours) }
            return String(format: L("in %d d"), days)
        }
        if hours > 0 {
            if minutes > 0 { return String(format: L("in %1$d h %2$d m"), hours, minutes) }
            return String(format: L("in %d h"), hours)
        }
        return String(format: L("in %d m"), totalMinutes)
    }

    static func resetDescription(from date: Date, now: Date = .init()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return self.formattedTime(date)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return String(format: L("tomorrow, %@"), self.formattedTime(date))
        }
        return date.formatted(
            Date.FormatStyle()
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
                .locale(codexBarLocalizationLocale()))
    }

    private static func formattedTime(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle()
                .hour()
                .minute()
                .locale(codexBarLocalizationLocale()))
    }
}
