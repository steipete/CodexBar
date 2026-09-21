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

    // MARK: Cell widths

    @Test
    func `wide characters occupy two cells before absolute column addressing`() {
        // "Org: " fills columns 1-5, each ideograph two columns, so column 10 is right after "文".
        let stream = "\u{1B}[HOrg: 中文\u{1B}[10G Labs"
        #expect(TerminalScreenRenderer.render(stream, columns: 40, rows: 2) == "Org: 中文 Labs")
    }

    @Test
    func `emoji occupy two cells before absolute column addressing`() {
        #expect(TerminalScreenRenderer.render("\u{1B}[H🎉 ok\u{1B}[4GX", columns: 40, rows: 2) == "🎉 Xk")
        #expect(TerminalScreenRenderer.render("\u{1B}[H⚠️ ok\u{1B}[4GX", columns: 40, rows: 2) == "⚠️ Xk")
    }

    @Test
    func `ambiguous width characters stay one cell like string-width`() {
        // Claude's usage bars are drawn with U+2588/U+258C; Ink counts them as one column each.
        #expect(TerminalScreenRenderer.render("\u{1B}[H██▌\u{1B}[5G51%", columns: 40, rows: 2) == "██▌ 51%")
    }

    @Test
    func `overwriting half of a wide character blanks the rest of it`() {
        // "a" lands on the second half of 中 and "b" on the first half of 文.
        #expect(TerminalScreenRenderer.render("\u{1B}[H中文\u{1B}[2Gab", columns: 40, rows: 2) == " ab")
        // Erasing from inside 文 removes the whole glyph.
        #expect(TerminalScreenRenderer.render("\u{1B}[H中文x\u{1B}[4G\u{1B}[K", columns: 40, rows: 2) == "中")
    }

    @Test
    func `a wide character that does not fit wraps to the next row`() {
        #expect(TerminalScreenRenderer.render("\u{1B}[Habcd中e", columns: 5, rows: 3) == "abcd\n中e")
        #expect(TerminalScreenRenderer.render("\u{1B}[Habc中e", columns: 5, rows: 3) == "abc中\ne")
    }

    @Test
    func `combining marks split from their base by an escape still join it`() {
        #expect(TerminalScreenRenderer.render("\u{1B}[He\u{1B}[0m\u{301}x", columns: 10, rows: 2) == "\u{E9}x")
    }
}
