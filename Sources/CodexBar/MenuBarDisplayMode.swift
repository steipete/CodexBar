import CodexBarCore
import Foundation

/// Controls what the menu bar displays when brand icon mode is enabled.
enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case percent
    case pace
    case both
    case allMetrics
    case resetTime

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .percent: L("display_mode_percent")
        case .pace: L("display_mode_pace")
        case .both: L("display_mode_both")
        case .allMetrics: L("display_mode_all_metrics")
        case .resetTime: L("display_mode_reset_time")
        }
    }

    var description: String {
        switch self {
        case .percent: L("display_mode_percent_desc")
        case .pace: L("display_mode_pace_desc")
        case .both: L("display_mode_both_desc")
        case .allMetrics: L("display_mode_all_metrics_desc")
        case .resetTime: L("display_mode_reset_time_desc")
        }
    }
}

/// Controls how Codex weekly pace is labeled inside the all-metrics menu bar text.
enum CodexAllMetricsPaceLabelStyle: String, CaseIterable, Identifiable {
    case abbreviated
    case word
    case valueOnly
    case delta

    var id: String {
        self.rawValue
    }

    var previewLabel: String {
        switch self {
        case .abbreviated: "P -23%"
        case .word: "\(L("display_mode_pace")) -23%"
        case .valueOnly: "-23%"
        case .delta: "Δ -23%"
        }
    }
}

/// Controls how the Codex weekly reset is rendered inside the all-metrics menu bar text.
enum CodexAllMetricsResetFormat: String, CaseIterable, Identifiable {
    case `default`
    case weekdayTime
    case monthDayTime
    case weekdayMonthDay
    case monthDay
    case weekdayTimeCompactCountdown
    case monthDayTimeCompactCountdown
    case weekdayMonthDayCompactCountdown
    case monthDayCompactCountdown
    case compactCountdown
    case countdown

    var id: String {
        self.rawValue
    }

    var previewLabel: String {
        self.previewLabel(locale: codexBarLocalizedLocale())
    }

    func previewLabel(locale: Locale) -> String {
        MenuBarDisplayText.codexAllMetricsResetPreview(format: self, locale: locale)
    }

    func usesCountdown(globalStyle: ResetTimeDisplayStyle) -> Bool {
        switch self {
        case .default:
            globalStyle == .countdown
        case .weekdayTimeCompactCountdown, .monthDayTimeCompactCountdown, .weekdayMonthDayCompactCountdown,
             .monthDayCompactCountdown, .compactCountdown, .countdown:
            true
        case .weekdayTime, .monthDayTime, .weekdayMonthDay, .monthDay:
            false
        }
    }
}
