import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuBarResetTimeDisplayTests {
    @Test
    func `reset time mode formats the selected window reset`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetsAt = now.addingTimeInterval(2 * 3600)
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: resetsAt,
            resetDescription: nil)

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: true,
            resetTimeDisplayStyle: .absolute,
            now: now)

        #expect(text == "↻ \(UsageFormatter.resetDescription(from: resetsAt, now: now))")
    }

    @Test
    func `reset time mode uses countdown preference`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetsAt = now.addingTimeInterval(2 * 3600 + 15 * 60)
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: resetsAt,
            resetDescription: nil)

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: true,
            resetTimeDisplayStyle: .countdown,
            now: now)

        #expect(text == "↻ in 2h 15m")
    }

    @Test
    func `reset time mode falls back to used percent without reset metadata`() {
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: true)

        #expect(text == "42%")
    }

    @Test
    func `reset time mode uses text reset metadata`() {
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: "in 2h 15m")

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: true)

        #expect(text == "↻ in 2h 15m")
    }

    @Test(arguments: [
        "Resets in 2h",
        "tomorrow, 3:00 PM",
        "next week",
        "expires in 4d",
    ])
    func `reset time mode accepts reset timing phrases`(_ description: String) {
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: description)

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: true)

        #expect(text == "↻ \(description)")
    }

    @Test(arguments: [
        "250/1000 requests",
        "160 requests",
        "5 hours window",
        "$10.00 available",
    ])
    func `reset time mode rejects non-reset provider summaries`(_ description: String) {
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: description)

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: true)

        #expect(text == "42%")
    }

    @Test
    func `reset time mode falls back to remaining percent without reset metadata`() {
        let window = RateWindow(
            usedPercent: 42,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)

        let text = MenuBarDisplayText.displayText(
            mode: .resetTime,
            percentWindow: window,
            showUsed: false)

        #expect(text == "58%")
    }

    @Test
    func `codex all metrics formats session weekly pace and reset`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionWindow = RateWindow(
            usedPercent: 22,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)
        let weeklyWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)
        let pace = try #require(UsagePace.weekly(window: weeklyWindow, now: now))

        let text = MenuBarDisplayText.codexAllMetricsText(
            sessionWindow: sessionWindow,
            weeklyWindow: weeklyWindow,
            weeklyPace: pace,
            showUsed: true,
            resetTimeDisplayStyle: .countdown,
            now: now)

        #expect(text == "5h 22% · W 50% · P +7% · ↻ in 4d")
    }

    @Test
    func `codex all metrics respects remaining percent preference`() {
        let sessionWindow = RateWindow(
            usedPercent: 22,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)
        let weeklyWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: nil,
            resetDescription: "in 4d")

        let text = MenuBarDisplayText.codexAllMetricsText(
            sessionWindow: sessionWindow,
            weeklyWindow: weeklyWindow,
            weeklyPace: nil,
            showUsed: false)

        #expect(text == "5h 78% · W 50% · ↻ in 4d")
    }

    @Test(arguments: [
        (CodexAllMetricsPaceLabelStyle.abbreviated, "P -23%"),
        (CodexAllMetricsPaceLabelStyle.word, "Pace -23%"),
        (CodexAllMetricsPaceLabelStyle.valueOnly, "-23%"),
        (CodexAllMetricsPaceLabelStyle.delta, "Δ -23%"),
    ])
    func `codex all metrics applies pace label style`(
        style: CodexAllMetricsPaceLabelStyle,
        expected: String)
    {
        let weeklyWindow = RateWindow(
            usedPercent: 0,
            windowMinutes: 10080,
            resetsAt: nil,
            resetDescription: nil)
        let pace = UsagePace(
            stage: .behind,
            deltaPercent: -23,
            expectedUsedPercent: 34,
            actualUsedPercent: 57,
            etaSeconds: nil,
            willLastToReset: false)

        let text = MenuBarDisplayText.codexAllMetricsText(
            sessionWindow: nil,
            weeklyWindow: weeklyWindow,
            weeklyPace: pace,
            showUsed: false,
            showsSession: false,
            showsWeekly: false,
            showsReset: false,
            paceLabelStyle: style)

        #expect(text == expected)
    }

    @Test(arguments: [
        (CodexAllMetricsResetFormat.weekdayTime, "↻ Thu 06:10"),
        (CodexAllMetricsResetFormat.monthDayTime, "↻ 18 Jun at 06:10"),
        (CodexAllMetricsResetFormat.weekdayMonthDay, "↻ Thu 18 Jun"),
        (CodexAllMetricsResetFormat.monthDay, "↻ 18 Jun"),
        (CodexAllMetricsResetFormat.weekdayTimeCompactCountdown, "↻ Thu 06:10 · 3d"),
        (CodexAllMetricsResetFormat.monthDayTimeCompactCountdown, "↻ 18 Jun at 06:10 · 3d"),
        (CodexAllMetricsResetFormat.weekdayMonthDayCompactCountdown, "↻ Thu 18 Jun · 3d"),
        (CodexAllMetricsResetFormat.monthDayCompactCountdown, "↻ 18 Jun · 3d"),
        (CodexAllMetricsResetFormat.compactCountdown, "↻ 3d"),
        (CodexAllMetricsResetFormat.countdown, "↻ in 3d"),
    ])
    func `codex all metrics applies reset format`(
        format: CodexAllMetricsResetFormat,
        expected: String)
        throws
    {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 6, minute: 10)))
        let resetsAt = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 6, day: 18, hour: 6, minute: 10)))
        let weeklyWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let text = MenuBarDisplayText.codexAllMetricsText(
            sessionWindow: nil,
            weeklyWindow: weeklyWindow,
            weeklyPace: nil,
            showUsed: false,
            showsSession: false,
            showsWeekly: false,
            showsPace: false,
            resetFormat: format,
            resetTimeDisplayStyle: .absolute,
            locale: Locale(identifier: "en_GB"),
            now: now)

        #expect(text == expected)
    }

    @Test
    func `codex all metrics hybrid reset format uses hours and minutes below one day`() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 6, day: 18, hour: 6, minute: 10)))
        let resetsAt = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 6, day: 18, hour: 9, minute: 41)))
        let weeklyWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let text = MenuBarDisplayText.codexAllMetricsText(
            sessionWindow: nil,
            weeklyWindow: weeklyWindow,
            weeklyPace: nil,
            showUsed: false,
            showsSession: false,
            showsWeekly: false,
            showsPace: false,
            resetFormat: .weekdayTimeCompactCountdown,
            resetTimeDisplayStyle: .absolute,
            locale: Locale(identifier: "en_GB"),
            now: now)

        #expect(text == "↻ Thu 09:41 · 3h 31m")
    }

    @Test
    func `codex all metrics reset previews honor locale hour cycle`() {
        let us = CodexAllMetricsResetFormat.weekdayTime.previewLabel(locale: Locale(identifier: "en_US"))
        let gb = CodexAllMetricsResetFormat.weekdayTime.previewLabel(locale: Locale(identifier: "en_GB"))

        #expect(us.contains("PM"))
        #expect(gb.hasSuffix("18:10"))
        #expect(!gb.contains("PM"))
    }

    @Test
    func `codex all metrics reset previews honor app language override`() {
        let preview = CodexBarLocalizationOverride.$appLanguage.withValue("fr") {
            CodexAllMetricsResetFormat.weekdayMonthDay.previewLabel
        }

        #expect(preview.contains("jeu."))
        #expect(preview.contains("juin"))
    }

    @Test
    func `codex all metrics omits disabled parts`() {
        let sessionWindow = RateWindow(
            usedPercent: 22,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)
        let weeklyWindow = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: nil,
            resetDescription: "in 4d")
        let pace = UsagePace(
            stage: .behind,
            deltaPercent: -23,
            expectedUsedPercent: 34,
            actualUsedPercent: 57,
            etaSeconds: nil,
            willLastToReset: false)

        let text = MenuBarDisplayText.codexAllMetricsText(
            sessionWindow: sessionWindow,
            weeklyWindow: weeklyWindow,
            weeklyPace: pace,
            showUsed: false,
            showsSession: false,
            showsWeekly: true,
            showsPace: false,
            showsReset: true,
            paceLabelStyle: .word)

        #expect(text == "W 50% · ↻ in 4d")
    }
}
