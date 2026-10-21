import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLIScreenTests {
    @Test(arguments: [
        ("abc\rZ", "Zbc"),
        ("one\r\ntwo\nthree", "one\ntwo\nthree"),
        ("abc\u{8}Z", "abZ"),
        ("abc\r\u{1b}[2CZ", "abZ"),
        ("abc\u{1b}[2DZ", "aZc"),
        ("a\u{1b}[2Cb", "a  b"),
        ("abc\r\u{1b}[CZ", "aZc"),
        ("abc\u{1b}[DZ", "abZ"),
        ("one\r\ntwo\u{1b}[1A\u{1b}[1GX", "Xne\ntwo"),
        ("one\r\u{1b}[2Btwo", "one\n\ntwo"),
        ("abc\u{1b}[2GZ", "aZc"),
        ("abc\u{1b}[2;2HZ", "abc\n Z"),
        ("abc\u{1b}[2;2fZ", "abc\n Z"),
        ("abc\u{1b}[0;0HZ", "Zbc"),
        ("one\r\ntwo\u{1b}[HZ", "Zne\ntwo"),
        ("abc\r\u{1b}[2G\u{1b}[K", "a"),
        ("abc\u{1b}[2G\u{1b}[1K", "  c"),
        ("abc\u{1b}[2K", ""),
        ("abc\nxyz\u{1b}[1;2H\u{1b}[J", "a"),
        ("abc\nxyz\u{1b}[2;2H\u{1b}[1J", "\n  z"),
        ("abc\nxyz\u{1b}[2JQ", "\n   Q"),
        ("a\u{1b}[38;5;42mb\u{1b}[0m\u{1b}[?25lc", "abc"),
        ("a\u{1b}]0;hidden\u{7}b\u{1b}]8;;hidden\u{1b}\\c", "abc"),
        ("a\u{1b}]0;hidden", "a"),
        ("a\u{1b}[123;", "a"),
        ("a\u{1b}[?2J\u{1b}[99K\u{1b}[99Jb", "ab"),
        ("Org: 中文\u{1b}[10G Labs", "Org: 中文 Labs"),
        ("🎉 ok\u{1b}[4GX", "🎉 Xk"),
        ("⚠️ ok\u{1b}[4GX", "⚠️ Xk"),
        ("██▌\u{1b}[5G51%", "██▌ 51%"),
        ("中文\u{1b}[2Gab", " ab"),
        ("中文x\u{1b}[4G\u{1b}[K", "中"),
        ("e\u{1b}[0m\u{301}x", "éx"),
    ])
    func `cursor and erase operations preserve visible cells`(stream: String, expected: String) {
        #expect(ClaudeCLIScreen.render(stream) == expected)
    }

    @Test
    func `synthetic differential frame matches the visible panel golden`() throws {
        let frame = """
        \u{1b}[HCurrent session
        3% used
        Current week (all models)
        27% used
        Current week (Fable)
        abc xye jkl
        """ + "\u{1b}[6;1H51%\u{1b}[5Gus\u{1b}[8Gd\u{1b}[9G\u{1b}[K"
        let golden = """
        Current session
        3% used
        Current week (all models)
        27% used
        Current week (Fable)
        51% used
        """
        #expect(ClaudeCLIScreen.render(frame) == golden)
        let actual = try ClaudeStatusProbe.parse(text: frame)
        let expected = try ClaudeStatusProbe.parse(text: golden)
        #expect(actual.sessionPercentLeft == expected.sessionPercentLeft)
        #expect(actual.weeklyPercentLeft == expected.weeklyPercentLeft)
        #expect(actual.extraRateWindows == expected.extraRateWindows)
    }

    @Test
    func `backspace edits are replayed without a CSI sequence`() throws {
        let snapshot = try ClaudeStatusProbe.parse(text: "Current session\n39\u{8}5% used")
        #expect(snapshot.sessionPercentLeft == 65)
    }

    @Test
    func `clearing the screen cannot resurrect an earlier quota`() {
        let frame = "\u{1b}[HCurrent session\n3% used\u{1b}[2J"
        #expect(throws: ClaudeStatusProbeError.self) { try ClaudeStatusProbe.parse(text: frame) }
    }

    @Test
    func `positions and overflowing parameters remain bounded to the PTY geometry`() {
        let huge = String(repeating: "9", count: 100)
        let frame = "\u{1b}[\(huge);\(huge)HQ\u{1b}[\(huge)AZ\u{1b}[\(huge)DX"
        let lines = ClaudeCLIScreen.render(frame).components(separatedBy: "\n")
        #expect(lines.count == ClaudeCLIScreen.rows)
        #expect(lines.allSatisfy { $0.count <= ClaudeCLIScreen.columns })
        #expect(lines[0] == "X" + String(repeating: " ", count: ClaudeCLIScreen.columns - 2) + "Z")
        #expect(lines.last == String(repeating: " ", count: ClaudeCLIScreen.columns - 1) + "Q")
    }

    @Test
    func `wrap and line feed retain only the visible screen`() {
        let full = String(repeating: "x", count: ClaudeCLIScreen.columns)
        #expect(ClaudeCLIScreen.render(full + "Z") == full + "\nZ")
        #expect(ClaudeCLIScreen.render(full + "\u{1b}[31mZ") == full + "\nZ")
        #expect(ClaudeCLIScreen.render(full + "\u{1b}[99KZ") == full + "\nZ")
        let narrow = String(repeating: "x", count: ClaudeCLIScreen.columns - 1)
        #expect(ClaudeCLIScreen.render(narrow + "中Z") == narrow + "\n中Z")
        let rows = (0...ClaudeCLIScreen.rows).map(String.init)
        #expect(ClaudeCLIScreen.render(rows.joined(separator: "\r\n")) == rows.dropFirst().joined(separator: "\n"))
    }

    @Test(arguments: ["200C", "200G", "200;200H", "200;200f"])
    func `tall screen cursor moves still clamp to the last column`(movement: String) {
        let frame = "top\u{1b}[200B\u{1b}[\(movement)X"
        let lines = ClaudeCLIScreen.render(frame).components(separatedBy: "\n")
        #expect(lines.count == 200)
        #expect(lines.first == "top")
        #expect(lines.last == String(repeating: " ", count: ClaudeCLIScreen.columns - 1) + "X")
    }

    @Test
    func `erase below the old column bound removes the entire quota`() {
        let frame = "\u{1b}[180;1HCurrent session\n7% used\u{1b}[200;1Hfooter"
            + "\u{1b}[180;1H\u{1b}[J"
        #expect(ClaudeCLIScreen.render(frame).isEmpty)
        #expect(throws: ClaudeStatusProbeError.self) { try ClaudeStatusProbe.parse(text: frame) }
    }
}
