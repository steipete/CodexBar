import CodexBarCore
import Testing

@Suite
struct TextParsingTests {
    @Test
    func stripANSICodesRemovesCursorVisibilityCSI() {
        let input = "\u{001B}[?25hhello\u{001B}[0m"
        let stripped = TextParsing.stripANSICodes(input)
        #expect(stripped == "hello")
    }

    // MARK: - parseLocalizedNumber tests

    @Test
    func parseLocalizedNumberHandlesUSDecimal() {
        #expect(TextParsing.parseLocalizedNumber("20.00") == 20.0)
        #expect(TextParsing.parseLocalizedNumber("1234.56") == 1234.56)
        #expect(TextParsing.parseLocalizedNumber("0.99") == 0.99)
    }

    @Test
    func parseLocalizedNumberHandlesEuropeanDecimal() {
        // European format: comma as decimal separator
        #expect(TextParsing.parseLocalizedNumber("20,00") == 20.0)
        #expect(TextParsing.parseLocalizedNumber("20,5") == 20.5)
        #expect(TextParsing.parseLocalizedNumber("0,99") == 0.99)
    }

    @Test
    func parseLocalizedNumberHandlesUSThousands() {
        // US format: comma as thousands separator
        #expect(TextParsing.parseLocalizedNumber("1,000") == 1000.0)
        #expect(TextParsing.parseLocalizedNumber("1,234,567") == 1234567.0)
    }

    @Test
    func parseLocalizedNumberHandlesUSThousandsWithDecimal() {
        // US format: comma thousands + dot decimal
        #expect(TextParsing.parseLocalizedNumber("1,234.56") == 1234.56)
        #expect(TextParsing.parseLocalizedNumber("1,000,000.99") == 1000000.99)
    }

    @Test
    func parseLocalizedNumberHandlesEuropeanThousandsWithDecimal() {
        // European format: dot thousands + comma decimal
        #expect(TextParsing.parseLocalizedNumber("1.234,56") == 1234.56)
        #expect(TextParsing.parseLocalizedNumber("1.000.000,99") == 1000000.99)
    }

    @Test
    func parseLocalizedNumberHandlesPlainIntegers() {
        #expect(TextParsing.parseLocalizedNumber("100") == 100.0)
        #expect(TextParsing.parseLocalizedNumber("0") == 0.0)
        #expect(TextParsing.parseLocalizedNumber("999999") == 999999.0)
    }

    @Test
    func parseLocalizedNumberHandlesWhitespace() {
        #expect(TextParsing.parseLocalizedNumber("  20,00  ") == 20.0)
        #expect(TextParsing.parseLocalizedNumber(" 1,234.56 ") == 1234.56)
    }

    @Test
    func parseLocalizedNumberReturnsNilForEmpty() {
        #expect(TextParsing.parseLocalizedNumber("") == nil)
        #expect(TextParsing.parseLocalizedNumber("   ") == nil)
    }

    @Test
    func parseLocalizedNumberReturnsNilForInvalid() {
        #expect(TextParsing.parseLocalizedNumber("abc") == nil)
        #expect(TextParsing.parseLocalizedNumber("12.34.56") == nil)
    }

    // MARK: - firstNumber regression tests

    @Test
    func firstNumberParsesEuropeanCredits() {
        // The bug: "Credits: 20,00" was being parsed as 2000.00
        let text = "Credits remaining: 20,00"
        let pattern = #"credits\s*remaining[^0-9]*([0-9][0-9.,]*)"#
        let result = TextParsing.firstNumber(pattern: pattern, text: text)
        #expect(result == 20.0)
    }

    @Test
    func firstNumberParsesUSCredits() {
        let text = "Credits remaining: 1,234.56"
        let pattern = #"credits\s*remaining[^0-9]*([0-9][0-9.,]*)"#
        let result = TextParsing.firstNumber(pattern: pattern, text: text)
        #expect(result == 1234.56)
    }

    @Test
    func firstNumberParsesEuropeanLargeCredits() {
        let text = "Credits remaining: 1.234,56"
        let pattern = #"credits\s*remaining[^0-9]*([0-9][0-9.,]*)"#
        let result = TextParsing.firstNumber(pattern: pattern, text: text)
        #expect(result == 1234.56)
    }
}
