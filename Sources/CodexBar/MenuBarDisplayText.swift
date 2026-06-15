import CodexBarCore
import Foundation

enum MenuBarDisplayText {
    static func percentText(window: RateWindow?, showUsed: Bool) -> String? {
        guard let window else { return nil }
        let percent = showUsed ? window.usedPercent : window.remainingPercent
        let clamped = min(100, max(0, percent))
        return String(format: "%.0f%%", clamped)
    }

    static func paceText(pace: UsagePace?) -> String? {
        guard let pace else { return nil }
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        let sign = pace.deltaPercent >= 0 ? "+" : "-"
        return "\(sign)\(deltaValue)%"
    }

    static func displayText(
        mode: MenuBarDisplayMode,
        percentWindow: RateWindow?,
        pace: UsagePace? = nil,
        showUsed: Bool,
        resetTimeDisplayStyle: ResetTimeDisplayStyle = .countdown,
        now: Date = .init()) -> String?
    {
        switch mode {
        case .percent:
            return self.percentText(window: percentWindow, showUsed: showUsed)
        case .pace:
            // Pace can be temporarily unavailable near a reset or when a provider omits window metadata.
            // Keep the selected quota visible instead of collapsing the status item to an icon-only state.
            return self.paceText(pace: pace)
                ?? self.percentText(window: percentWindow, showUsed: showUsed)
        case .both:
            guard let percent = percentText(window: percentWindow, showUsed: showUsed) else { return nil }
            // Fall back to percent-only when pace is unavailable (e.g. Copilot)
            guard let paceText = Self.paceText(pace: pace) else { return percent }
            return "\(percent) · \(paceText)"
        case .allMetrics:
            guard let percent = percentText(window: percentWindow, showUsed: showUsed) else { return nil }
            guard let paceText = Self.paceText(pace: pace) else { return percent }
            return "\(percent) · \(paceText)"
        case .resetTime:
            guard let percentWindow else { return nil }
            return self.resetText(window: percentWindow, style: resetTimeDisplayStyle, now: now)
                ?? self.percentText(window: percentWindow, showUsed: showUsed)
        }
    }

    static func codexAllMetricsText(
        sessionWindow: RateWindow?,
        weeklyWindow: RateWindow?,
        weeklyPace: UsagePace?,
        showUsed: Bool,
        showsSession: Bool = true,
        showsWeekly: Bool = true,
        showsPace: Bool = true,
        showsReset: Bool = true,
        paceLabelStyle: CodexAllMetricsPaceLabelStyle = .abbreviated,
        resetFormat: CodexAllMetricsResetFormat = .default,
        resetTimeDisplayStyle: ResetTimeDisplayStyle = .countdown,
        now: Date = .init())
        -> String?
    {
        var parts: [String] = []
        if showsSession, let session = self.percentText(window: sessionWindow, showUsed: showUsed) {
            parts.append("5h \(session)")
        }
        if showsWeekly, let weekly = self.percentText(window: weeklyWindow, showUsed: showUsed) {
            parts.append("W \(weekly)")
        }
        if showsPace, let pace = self.paceText(pace: weeklyPace) {
            parts.append(self.codexAllMetricsPaceText(pace, style: paceLabelStyle))
        }
        if showsReset,
           let reset = self.codexAllMetricsResetText(
               window: weeklyWindow,
               format: resetFormat,
               defaultStyle: resetTimeDisplayStyle,
               now: now)
        {
            parts.append(reset)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func codexAllMetricsResetText(
        window: RateWindow?,
        format: CodexAllMetricsResetFormat,
        defaultStyle: ResetTimeDisplayStyle,
        now: Date)
        -> String?
    {
        guard let window else { return nil }
        guard let resetsAt = window.resetsAt else {
            return self.resetMetadataText(window.resetDescription).map { "↻ \($0)" }
        }

        let description = switch format {
        case .default:
            switch defaultStyle {
            case .countdown:
                UsageFormatter.resetCountdownDescription(from: resetsAt, now: now)
            case .absolute:
                UsageFormatter.resetDescription(from: resetsAt, now: now)
            }
        case .weekdayTime:
            self.compactDateText(resetsAt, format: "EEE h:mma")
        case .monthDayTime:
            self.compactDateText(resetsAt, format: "MMM d h:mma")
        case .weekdayMonthDay:
            self.compactDateText(resetsAt, format: "EEE MMM d")
        case .monthDay:
            self.compactDateText(resetsAt, format: "MMM d")
        case .weekdayTimeCompactCountdown:
            self.compactResetText(resetsAt, dateFormat: "EEE h:mma", now: now)
        case .monthDayTimeCompactCountdown:
            self.compactResetText(resetsAt, dateFormat: "MMM d h:mma", now: now)
        case .weekdayMonthDayCompactCountdown:
            self.compactResetText(resetsAt, dateFormat: "EEE MMM d", now: now)
        case .monthDayCompactCountdown:
            self.compactResetText(resetsAt, dateFormat: "MMM d", now: now)
        case .compactCountdown:
            self.compactCountdownText(resetsAt, now: now)
        case .countdown:
            UsageFormatter.resetCountdownDescription(from: resetsAt, now: now)
        }
        return "↻ \(description)"
    }

    private static func codexAllMetricsPaceText(
        _ pace: String,
        style: CodexAllMetricsPaceLabelStyle)
        -> String
    {
        switch style {
        case .abbreviated:
            "P \(pace)"
        case .word:
            "Pace \(pace)"
        case .valueOnly:
            pace
        case .delta:
            "Δ \(pace)"
        }
    }

    private static func compactCountdownText(_ date: Date, now: Date) -> String {
        let countdown = UsageFormatter.resetCountdownDescription(from: date, now: now)
        guard countdown.hasPrefix("in ") else { return countdown }
        return String(countdown.dropFirst(3))
    }

    private static func compactResetText(_ date: Date, dateFormat: String, now: Date) -> String {
        "\(self.compactDateText(date, format: dateFormat)) · \(self.compactCountdownText(date, now: now))"
    }

    private static func compactDateText(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
            .replacingOccurrences(of: "AM", with: "a")
            .replacingOccurrences(of: "PM", with: "p")
    }

    private static func resetText(window: RateWindow?, style: ResetTimeDisplayStyle, now: Date) -> String? {
        guard let window else { return nil }
        if let resetsAt = window.resetsAt {
            let description = switch style {
            case .countdown:
                UsageFormatter.resetCountdownDescription(from: resetsAt, now: now)
            case .absolute:
                UsageFormatter.resetDescription(from: resetsAt, now: now)
            }
            return "↻ \(description)"
        }
        if let resetDescription = self.resetMetadataText(window.resetDescription) {
            return "↻ \(resetDescription)"
        }
        return nil
    }

    private static func resetMetadataText(_ description: String?) -> String? {
        guard let description else { return nil }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // RateWindow.resetDescription predates provider-specific detail fields and is also used for
        // request/token summaries. Only trust phrases that explicitly describe reset timing.
        let normalized = trimmed.lowercased()
        let resetPrefixes = [
            "reset ", "resets ", "in ", "today ", "today,", "tomorrow ", "tomorrow,", "next ",
            "expire ", "expires ", "refill ", "refills ",
        ]
        let exactResetDescriptions = ["today", "tomorrow", "expired", "now", "soon"]
        return exactResetDescriptions.contains(normalized) || resetPrefixes.contains(where: normalized.hasPrefix)
            ? trimmed
            : nil
    }
}
