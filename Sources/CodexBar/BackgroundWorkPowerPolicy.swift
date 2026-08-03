import Foundation

enum BackgroundWorkPowerPolicy {
    static let lowPowerMinimumInterval: TimeInterval = 30 * 60

    static func automaticInterval(
        _ requested: TimeInterval?,
        lowPowerModeEnabled: Bool) -> TimeInterval?
    {
        guard let requested else { return nil }
        guard lowPowerModeEnabled else { return requested }
        return max(requested, self.lowPowerMinimumInterval)
    }
}
