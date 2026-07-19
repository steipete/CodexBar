import Foundation

enum CodexRateWindowNormalizer {
    static func normalize(
        primary: RateWindow?,
        secondary: RateWindow?)
        -> (primary: RateWindow?, secondary: RateWindow?)
    {
        switch (primary, secondary) {
        case let (.some(primaryWindow), .some(secondaryWindow)):
            switch (self.role(for: primaryWindow), self.role(for: secondaryWindow)) {
            case (.session, .weekly), (.session, .unknown), (.unknown, .weekly):
                (primaryWindow, secondaryWindow)
            case (.weekly, .session), (.weekly, .unknown):
                (secondaryWindow, primaryWindow)
            default:
                (primaryWindow, secondaryWindow)
            }
        case let (.some(primaryWindow), .none):
            switch role(for: primaryWindow) {
            case .weekly:
                (nil, primaryWindow)
            case .session, .unknown:
                (primaryWindow, nil)
            }
        case let (.none, .some(secondaryWindow)):
            switch self.role(for: secondaryWindow) {
            case .session, .unknown:
                (secondaryWindow, nil)
            case .weekly:
                (nil, secondaryWindow)
            }
        case (.none, .none):
            (nil, nil)
        }
    }

    private enum WindowRole {
        case session
        case weekly
        case unknown
    }

    private static func role(for window: RateWindow) -> WindowRole {
        switch window.windowMinutes {
        case 300:
            .session
        case 10080:
            .weekly
        default:
            .unknown
        }
    }
}

#if DEBUG
extension CodexRateWindowNormalizer {
    static func _normalizeForTesting(
        primary: RateWindow?,
        secondary: RateWindow?)
        -> (primary: RateWindow?, secondary: RateWindow?)
    {
        self.normalize(primary: primary, secondary: secondary)
    }
}
#endif
