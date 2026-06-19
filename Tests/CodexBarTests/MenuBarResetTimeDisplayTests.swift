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
}
