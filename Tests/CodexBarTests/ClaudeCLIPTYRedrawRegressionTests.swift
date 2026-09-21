import Foundation
import Testing
@testable import CodexBarCore

/// Regression coverage for steipete/CodexBar#3746: a real `claude` PTY capture in which the Fable panel
/// is painted by a differential redraw. See Tests/CodexBarTests/Fixtures/Providers/Claude/.
struct ClaudeCLIPTYRedrawRegressionTests {
    private static func capture() throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: "usage-pty-differential-redraw",
            withExtension: "ansi",
            subdirectory: "Fixtures/Providers/Claude"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test
    func `differentially redrawn Fable panel survives parsing`() throws {
        let snapshot = try ClaudeStatusProbe.parse(text: Self.capture())

        #expect(snapshot.sessionPercentLeft == 97)
        #expect(snapshot.weeklyPercentLeft == 73)
        let fable = try #require(snapshot.extraRateWindows.first { $0.id == "claude-weekly-scoped-fable" })
        #expect(fable.title == "Fable only")
        #expect(fable.window.usedPercent == 51)
    }

    @Test
    func `reset descriptions keep the spaces the redraw skipped`() throws {
        let snapshot = try ClaudeStatusProbe.parse(text: Self.capture())

        #expect(snapshot.secondaryResetDescription == "Resets Sep 23 at 3pm (Europe/Stockholm)")
    }

    /// Documents why stripping escapes is not enough: the shared "e" of the previous frame's "does" is
    /// never retransmitted, so the naive text reads "51%usd" and the direction keyword is unrecognizable.
    @Test
    func `stripping escape codes alone loses the used keyword`() throws {
        let stripped = try TextParsing.stripANSICodes(Self.capture())

        #expect(stripped.contains("51%usd"))
        #expect(!stripped.contains("51% used"))
        #expect(try TerminalScreenRenderer.render(
            Self.capture(),
            columns: ClaudeCLISession.ptyColumns,
            rows: ClaudeCLISession.ptyRows).contains("51% used"))
    }

    /// A capture whose replay loses the percentages (here: the screen is wiped after the panel) degrades
    /// to the legacy strip instead of returning nothing. Captures without percentages keep the replay.
    @Test
    func `capture with an unexpected shape falls back to the plain strip`() {
        #expect(ClaudeStatusProbe.cleanCapture("3% used\u{1B}[2J") == "3% used")
        #expect(ClaudeStatusProbe.cleanCapture("Account: a@b.c\u{1B}[2J").isEmpty)
    }
}
