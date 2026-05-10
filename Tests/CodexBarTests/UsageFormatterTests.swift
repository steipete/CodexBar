import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UsageFormatterTests {
    @Test
    func `formats usage line`() {
        let line = UsageFormatter.usageLine(remaining: 25, used: 75, showUsed: false)
        #expect(line == "25% left")
    }

    @Test
    func `formats usage line show used`() {
        let line = UsageFormatter.usageLine(remaining: 25, used: 75, showUsed: true)
        #expect(line == "75% used")
    }

    @Test
    func `relative updated recent`() {
        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let text = UsageFormatter.updatedString(from: fiveHoursAgo, now: now)
        #expect(text.hasPrefix("Updated "))
        // Output must stay in English regardless of the host system locale,
        // matching the surrounding hardcoded English UI labels.
        #expect(text.contains("5"))
        #expect(text.lowercased().contains("ago"))
    }

    @Test
    func `absolute updated old`() {
        let now = Date()
        let dayAgo = now.addingTimeInterval(-26 * 3600)
        let text = UsageFormatter.updatedString(from: dayAgo, now: now)
        #expect(text.contains("Updated"))
        #expect(!text.contains("ago"))
    }

    @Test
    func `reset countdown minutes`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(10 * 60 + 1)
        #expect(UsageFormatter.resetCountdownDescription(from: reset, now: now) == "in 11m")
    }

    @Test
    func `reset countdown hours and minutes`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(3 * 3600 + 31 * 60)
        #expect(UsageFormatter.resetCountdownDescription(from: reset, now: now) == "in 3h 31m")
    }

    @Test
    func `reset countdown days and hours`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval((26 * 3600) + 10)
        #expect(UsageFormatter.resetCountdownDescription(from: reset, now: now) == "in 1d 2h")
    }

    @Test
    func `reset countdown exact hour`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(60 * 60)
        #expect(UsageFormatter.resetCountdownDescription(from: reset, now: now) == "in 1h")
    }

    @Test
    func `reset countdown past date`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(-10)
        #expect(UsageFormatter.resetCountdownDescription(from: reset, now: now) == "now")
    }

    @Test
    func `reset line uses countdown when resets at is available`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(10 * 60 + 1)
        let window = RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: reset, resetDescription: "Resets soon")
        let text = UsageFormatter.resetLine(for: window, style: .countdown, now: now)
        #expect(text == "Resets in 11m")
    }

    @Test
    func `reset line falls back to provided description`() {
        let window = RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "Resets at 23:30 (UTC)")
        let countdown = UsageFormatter.resetLine(for: window, style: .countdown)
        let absolute = UsageFormatter.resetLine(for: window, style: .absolute)
        #expect(countdown == "Resets at 23:30 (UTC)")
        #expect(absolute == "Resets at 23:30 (UTC)")
    }

    @Test
    func `model display name strips trailing dates`() {
        #expect(UsageFormatter.modelDisplayName("claude-opus-4-5-20251101") == "claude-opus-4-5")
        #expect(UsageFormatter.modelDisplayName("gpt-4o-2024-08-06") == "gpt-4o")
        #expect(UsageFormatter.modelDisplayName("Claude Opus 4.5 2025 1101") == "Claude Opus 4.5")
        #expect(UsageFormatter.modelDisplayName("claude-sonnet-4-5") == "claude-sonnet-4-5")
        #expect(UsageFormatter.modelDisplayName("gpt-5.3-codex-spark") == "gpt-5.3-codex-spark")
    }

    @Test
    func `model cost detail uses research preview label`() {
        #expect(
            UsageFormatter.modelCostDetail("gpt-5.3-codex-spark", costUSD: 0, totalTokens: nil) == "Research Preview")
        #expect(UsageFormatter.modelCostDetail("gpt-5.2-codex", costUSD: 0.42, totalTokens: nil) == "$0.42")
    }

    @Test
    func `model cost detail includes token counts when present`() {
        #expect(UsageFormatter.modelCostDetail("gpt-5.2-codex", costUSD: 0.42, totalTokens: 1200) == "$0.42 · 1.2K")
        #expect(
            UsageFormatter.modelCostDetail("gpt-5.3-codex-spark", costUSD: 0, totalTokens: 1500)
                == "Research Preview · 1.5K")
        #expect(UsageFormatter.modelCostDetail("custom-model", costUSD: nil, totalTokens: 987) == "987")
    }

    @Test
    func `clean plan maps O auth to ollama`() {
        #expect(UsageFormatter.cleanPlanName("oauth") == "Ollama")
    }

    // MARK: - Currency Formatting

    @Test
    func `currency string formats USD correctly`() {
        // Should produce "$54.72" without space after symbol
        let result = UsageFormatter.currencyString(54.72, currencyCode: "USD")
        #expect(result == "$54.72")
        #expect(!result.contains("$ ")) // No space after symbol
    }

    @Test
    func `currency string handles large values`() {
        let result = UsageFormatter.currencyString(1234.56, currencyCode: "USD")
        // For USD, we use direct string formatting with thousand separators
        #expect(result == "$1,234.56")
        #expect(!result.contains("$ ")) // No space after symbol
    }

    @Test
    func `currency string handles very large values`() {
        let result = UsageFormatter.currencyString(1_234_567.89, currencyCode: "USD")
        #expect(result == "$1,234,567.89")
    }

    @Test
    func `currency string handles negative values`() {
        // Negative sign should come before the dollar sign: -$54.72 (not $-54.72)
        let result = UsageFormatter.currencyString(-54.72, currencyCode: "USD")
        #expect(result == "-$54.72")
    }

    @Test
    func `currency string handles negative large values`() {
        let result = UsageFormatter.currencyString(-1234.56, currencyCode: "USD")
        #expect(result == "-$1,234.56")
    }

    @Test
    func `usd string matches currency string`() {
        // usdString should produce identical output to currencyString for USD
        #expect(UsageFormatter.usdString(54.72) == UsageFormatter.currencyString(54.72, currencyCode: "USD"))
        #expect(UsageFormatter.usdString(-1234.56) == UsageFormatter.currencyString(-1234.56, currencyCode: "USD"))
        #expect(UsageFormatter.usdString(0) == UsageFormatter.currencyString(0, currencyCode: "USD"))
    }

    @Test
    func `currency string handles zero`() {
        let result = UsageFormatter.currencyString(0, currencyCode: "USD")
        #expect(result == "$0.00")
    }

    @Test
    func `currency string handles non USD currencies`() {
        // FormatStyle handles all currencies with proper symbols
        let eur = UsageFormatter.currencyString(54.72, currencyCode: "EUR")
        #expect(eur == "€54.72")

        let gbp = UsageFormatter.currencyString(54.72, currencyCode: "GBP")
        #expect(gbp == "£54.72")

        // Negative non-USD
        let negEur = UsageFormatter.currencyString(-1234.56, currencyCode: "EUR")
        #expect(negEur == "-€1,234.56")
    }

    @Test
    func `currency string handles small values`() {
        // Values smaller than 0.01 should round to $0.00
        let tiny = UsageFormatter.currencyString(0.001, currencyCode: "USD")
        #expect(tiny == "$0.00")

        // Values at 0.005 should round to $0.01 (banker's rounding)
        let halfCent = UsageFormatter.currencyString(0.005, currencyCode: "USD")
        #expect(halfCent == "$0.00" || halfCent == "$0.01") // Rounding behavior may vary

        // One cent
        let oneCent = UsageFormatter.currencyString(0.01, currencyCode: "USD")
        #expect(oneCent == "$0.01")
    }

    @Test
    func `currency string handles boundary values`() {
        // Just under 1000 (no comma)
        let under1k = UsageFormatter.currencyString(999.99, currencyCode: "USD")
        #expect(under1k == "$999.99")

        // Exactly 1000 (first comma)
        let exact1k = UsageFormatter.currencyString(1000.00, currencyCode: "USD")
        #expect(exact1k == "$1,000.00")

        // Just over 1000
        let over1k = UsageFormatter.currencyString(1000.01, currencyCode: "USD")
        #expect(over1k == "$1,000.01")
    }

    @Test
    func `credits string formats correctly`() {
        let result = UsageFormatter.creditsString(from: 42.5)
        #expect(result == "42.5 left")
    }

    @Test
    func `byte count string formats binary units`() {
        #expect(UsageFormatter.byteCountString(0) == "0 B")
        #expect(UsageFormatter.byteCountString(512) == "512 B")
        #expect(UsageFormatter.byteCountString(1536) == "1.5 KB")
        #expect(UsageFormatter.byteCountString(10 * 1024) == "10 KB")
        #expect(UsageFormatter.byteCountString(5 * 1024 * 1024) == "5 MB")
        #expect(UsageFormatter.byteCountString(Int64(1536 * 1024 * 1024)) == "1.5 GB")
    }
}
