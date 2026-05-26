import Foundation

enum RelativeTimeFormatters {
    @MainActor
    static func full(locale: Locale) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter
    }
}

extension Date {
    @MainActor
    func relativeDescription(now: Date = .now) -> String {
        let seconds = abs(now.timeIntervalSince(self))
        if seconds < 15 {
            return L("just now")
        }
        let locale = codexBarLocalizedLocale()
        return RelativeTimeFormatters.full(locale: locale).localizedString(for: self, relativeTo: now)
    }
}
