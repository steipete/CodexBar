import Foundation
import Testing
@testable import CodexBarCore

struct TerminalScreenRendererTests {
    @Test
    func `plain text without escapes is returned unchanged`() {
        let text = "Current session\n9% used\n"
        #expect(TerminalScreenRenderer.render(text, columns: 160, rows: 50) == text)
    }

    @Test
    func `differential redraw keeps cells the previous frame already painted`() {
        // Ink skips cells whose content did not change, so "used" arrives as "us" + jump + "d" with the
        // shared "e" left over from the previous frame's "does". Stripping escapes would drop it.
        // Columns 4 and 7 already hold " " and "e", so the new frame transmits only "51%", "us" and "d".
        let stream = "abc xye jkl\r51%\u{1B}[5Gus\u{1B}[8Gd\u{1B}[9G\u{1B}[K"
        #expect(TerminalScreenRenderer.render(stream, columns: 40, rows: 4) == "51% used")
        #expect(TextParsing.stripANSICodes(stream).contains("51%usd"))
    }

    @Test
    func `absolute cursor addressing rebuilds a repainted panel`() {
        var stream = "\u{1B}[2J\u{1B}[H"
        stream += "\u{1B}[1;1HCurrent week (all models)"
        stream += "\u{1B}[2;1H27% used"
        stream += "\u{1B}[3;1HCurrent week (Fable)"
        stream += "\u{1B}[4;1H51% used"
        #expect(TerminalScreenRenderer.render(stream, columns: 40, rows: 10) == """
        Current week (all models)
        27% used
        Current week (Fable)
        51% used
        """)
    }

    @Test
    func `erase in line clears a stale remainder`() {
        let stream = "What's contributing to your limits usage?\r\u{1B}[1BCurrent week (Fable)\u{1B}[21G\u{1B}[K"
        let rendered = TerminalScreenRenderer.render(stream, columns: 60, rows: 4)
        #expect(rendered.split(separator: "\n").map(String.init) == [
            "What's contributing to your limits usage?",
            "Current week (Fable)",
        ])
    }

    @Test
    func `scrolled off lines are preserved as history`() {
        let stream = "\u{1B}[2J\u{1B}[Hone\r\ntwo\r\nthree\r\nfour"
        #expect(TerminalScreenRenderer.render(stream, columns: 20, rows: 2) == "one\ntwo\nthree\nfour")
    }

    @Test
    func `trailing blank screen rows are trimmed`() {
        let stream = "\u{1B}[2J\u{1B}[Hhello"
        #expect(TerminalScreenRenderer.render(stream, columns: 20, rows: 30) == "hello")
    }

    @Test
    func `unsupported sequences do not leak into the text`() {
        let stream = "\u{1B}]0;title\u{07}\u{1B}[38;5;42mcolored\u{1B}[0m\u{1B}[?25l"
        #expect(TerminalScreenRenderer.render(stream, columns: 20, rows: 2) == "colored")
    }

    @Test
    func `autowrap continues on the next row`() {
        #expect(TerminalScreenRenderer.render("\u{1B}[HabcdeF", columns: 5, rows: 3) == "abcde\nF")
    }
}
