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

    @Test
    func firstNumberParsesDecimalSeparators() {
        let dotDecimal = TextParsing.firstNumber(pattern: #"Credits:\s*([0-9][0-9., ]*)"#, text: "Credits: 54.72")
        #expect(dotDecimal == 54.72)

        let commaDecimal = TextParsing.firstNumber(pattern: #"Credits:\s*([0-9][0-9., ]*)"#, text: "Credits: 54,72")
        #expect(commaDecimal == 54.72)

        let mixedCommaDecimal = TextParsing.firstNumber(
            pattern: #"Credits:\s*([0-9][0-9., ]*)"#,
            text: "Credits: 1.234,56")
        #expect(mixedCommaDecimal == 1234.56)

        let mixedDotDecimal = TextParsing.firstNumber(
            pattern: #"Credits:\s*([0-9][0-9., ]*)"#,
            text: "Credits: 1,234.56")
        #expect(mixedDotDecimal == 1234.56)
    }
}
