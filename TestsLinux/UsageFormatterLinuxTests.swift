import CodexBarCore
import Testing

@Suite(.serialized)
struct UsageFormatterLinuxTests {
    @Test
    func `rate-window formatting uses the standalone English fallback`() {
        UsageFormatter.clearLocalizationProvider()
        UsageFormatter.clearLocaleProvider()

        #expect(UsageFormatter.usageLine(remaining: 25, used: 75, showUsed: false) == "25% left")
        #expect(UsageFormatter.usageLine(remaining: 25, used: 75, showUsed: true) == "75% used")
        #expect(UsageFormatter.usageLine(remaining: 0.75, used: 99.25, showUsed: false) == "<1% left")
    }

    @Test
    func `fractional percent keeps hundredths beside a whole percent`() {
        #expect(UsageFormatter.fractionalPercentText(99.60392845714286, suffix: "left") == "99.60% left")
        #expect(UsageFormatter.fractionalPercentText(2.01, suffix: "left") == "2.01% left")
        #expect(UsageFormatter.fractionalPercentText(2, suffix: "left") == nil)
    }
}
