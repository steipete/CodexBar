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
        locale: Locale = codexBarLocalizedLocale(),
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
               locale: locale,
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
        locale: Locale = codexBarLocalizedLocale(),
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
            self.compactDateText(resetsAt, template: "EEEjm", locale: locale)
        case .monthDayTime:
            self.compactDateText(resetsAt, template: "MMMdjm", locale: locale)
        case .weekdayMonthDay:
            self.compactDateText(resetsAt, template: "EEEMMMd", locale: locale)
        case .monthDay:
            self.compactDateText(resetsAt, template: "MMMd", locale: locale)
        case .weekdayTimeCompactCountdown:
            self.compactResetText(resetsAt, dateTemplate: "EEEjm", locale: locale, now: now)
        case .monthDayTimeCompactCountdown:
            self.compactResetText(resetsAt, dateTemplate: "MMMdjm", locale: locale, now: now)
        case .weekdayMonthDayCompactCountdown:
            self.compactResetText(resetsAt, dateTemplate: "EEEMMMd", locale: locale, now: now)
        case .monthDayCompactCountdown:
            self.compactResetText(resetsAt, dateTemplate: "MMMd", locale: locale, now: now)
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
            "\(L("display_mode_pace")) \(pace)"
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

    private static func compactResetText(
        _ date: Date,
        dateTemplate: String,
        locale: Locale,
        now: Date) -> String
    {
        "\(self.compactDateText(date, template: dateTemplate, locale: locale)) · " +
            self.compactCountdownText(date, now: now)
    }

    private static func compactDateText(_ date: Date, template: String, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    static func codexAllMetricsResetPreview(
        format: CodexAllMetricsResetFormat,
        locale: Locale = codexBarLocalizedLocale()) -> String
    {
        guard format != .default else { return L("Default") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        guard let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 18, minute: 10)),
              let reset = calendar.date(from: DateComponents(year: 2026, month: 6, day: 18, hour: 18, minute: 10))
        else {
            return L("Default")
        }
        let window = RateWindow(
            usedPercent: 0,
            windowMinutes: 10080,
            resetsAt: reset,
            resetDescription: nil)
        return self.codexAllMetricsResetText(
            window: window,
            format: format,
            defaultStyle: .countdown,
            locale: locale,
            now: now)?
            .replacingOccurrences(of: "↻ ", with: "") ?? L("Default")
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
