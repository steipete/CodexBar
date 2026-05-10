import Foundation

enum RelativeTimeFormatters {
    @MainActor
    static let full: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter
    }()
}

extension Date {
    @MainActor
    func relativeDescription(now: Date = .now) -> String {
        let seconds = abs(now.timeIntervalSince(self))
        if seconds < 15 {
            return "just now"
        }
        return RelativeTimeFormatters.full.localizedString(for: self, relativeTo: now)
    }
}
