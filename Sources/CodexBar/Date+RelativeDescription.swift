import Foundation

extension Date {
    @MainActor
    func relativeDescription(
        now: Date = .now,
        unitsStyle: RelativeDateTimeFormatter.UnitsStyle = .full)
        -> String
    {
        let seconds = abs(now.timeIntervalSince(self))
        if seconds < 15 {
            return AppStrings.tr("just now")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = unitsStyle
        formatter.locale = AppStrings.locale
        return formatter.localizedString(for: self, relativeTo: now)
    }
}
