import Foundation

extension Date {
    @MainActor
    func relativeDescription(now: Date = .now) -> String {
        let seconds = abs(now.timeIntervalSince(self))
        if seconds < 15 {
            return L("just now")
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = codexBarLocalizationLocale()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: now)
    }
}
