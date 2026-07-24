import CodexBarCore
import Foundation
import Testing

/// The Claude CLI renders /usage as a redrawing TUI, so a half-painted capture frame can drop a
/// character from "Current week (all models)" (-> "all modls"). These cover the shapes that matters:
/// the garbled copy must not become a bogus second weekly row, an exact copy must always win the
/// Weekly value regardless of order, the Weekly limit must still be recovered when only the garbled
/// copy survived, genuine model-scoped rows must be preserved, and the edit-distance boundary is
/// pinned so heavier corruption stays a (visible) scoped row rather than being silently absorbed.
struct ClaudeAllModelsWeeklyDuplicateTests {
    @Test
    func `garbled all-models copy does not duplicate the weekly row`() throws {
        let sample = """
        Settings:  Status   Config   Usage  (tab to cycle)

         Current session
         ▌                                                  0% used
         Resets 1:10pm (Asia/Seoul)

         Current week (all models)
         █████████████████████████████████▌                66% used
         Resets Jul 24 at 2pm (Asia/Seoul)

         Current week (all modls)
         █████████████████████████████████▌                67% used
         Resets Jul 24 at 1:59pm (Asia/Seoul)

         Current week (Fable)
         ████████████████████████████████████              71% used
         Resets Jul 24 at 2pm (Asia/Seoul)
        """

        let snap = try ClaudeStatusProbe.parse(text: sample)
        #expect(snap.weeklyPercentLeft == 34)
        let titles = snap.extraRateWindows.map(\.title)
        #expect(titles == ["Fable only"], "unexpected scoped weekly rows: \(titles)")
    }

    @Test
    func `exact all-models row wins over an earlier garbled duplicate`() throws {
        // Garbled 67% copy appears BEFORE the clean 66% copy; the Weekly value and reset must still
        // come from the exact row (34% left, 2pm), not the corrupted one that happens to be first.
        let sample = """
        Settings:  Status   Config   Usage  (tab to cycle)

         Current session
         ▌                                                  0% used
         Resets 1:10pm (Asia/Seoul)

         Current week (all modls)
         █████████████████████████████████▌                67% used
         Resets Jul 24 at 1:59pm (Asia/Seoul)

         Current week (all models)
         █████████████████████████████████▌                66% used
         Resets Jul 24 at 2pm (Asia/Seoul)
        """

        let snap = try ClaudeStatusProbe.parse(text: sample)
        #expect(snap.weeklyPercentLeft == 34)
        #expect(snap.secondaryResetDescription == "Resets Jul 24 at 2pm (Asia/Seoul)")
        #expect(snap.extraRateWindows.isEmpty, "garbled copy leaked as a scoped row")
    }

    @Test
    func `garbled all-models line still populates the weekly limit`() throws {
        // Only the corrupted all-models label survived this capture; the Weekly quota must be
        // recovered from it rather than dropped, and it must not appear as a scoped row.
        let sample = """
        Settings:  Status   Config   Usage  (tab to cycle)

         Current session
         ▌                                                  0% used
         Resets 1:10pm (Asia/Seoul)

         Current week (all modls)
         █████████████████████████████████▌                66% used
         Resets Jul 24 at 2pm (Asia/Seoul)

         Current week (Fable)
         ████████████████████████████████████              71% used
         Resets Jul 24 at 2pm (Asia/Seoul)
        """

        let snap = try ClaudeStatusProbe.parse(text: sample)
        #expect(snap.weeklyPercentLeft == 34)
        #expect(snap.secondaryResetDescription == "Resets Jul 24 at 2pm (Asia/Seoul)")
        let titles = snap.extraRateWindows.map(\.title)
        #expect(titles == ["Fable only"], "unexpected scoped weekly rows: \(titles)")
    }

    @Test
    func `single-character insertion is treated as all-models`() throws {
        // A dropped-then-doubled render ("all modelss", edit distance 1) is still the aggregate row.
        let sample = """
         Current session
         ▌                                                  0% used
         Resets 1:10pm (Asia/Seoul)

         Current week (all modelss)
         █████████████████████████████████▌                66% used
         Resets Jul 24 at 2pm (Asia/Seoul)

         Current week (Fable)
         ████████████████████████████████████              71% used
         Resets Jul 24 at 2pm (Asia/Seoul)
        """

        let snap = try ClaudeStatusProbe.parse(text: sample)
        #expect(snap.weeklyPercentLeft == 34)
        #expect(snap.extraRateWindows.map(\.title) == ["Fable only"])
    }

    @Test
    func `genuine scoped model is preserved and leaves the weekly limit unset`() throws {
        // No all-models row at all: the Weekly limit must be nil and the scoped Haiku row kept.
        // (Sonnet/Opus are folded into opusPercentLeft, so Haiku is used to exercise the extra-row path.)
        let sample = """
         Current session
         ▌                                                  0% used
         Resets 1:10pm (Asia/Seoul)

         Current week (Haiku)
         █▌                                                 10% used
         Resets Jul 24 at 2pm (Asia/Seoul)
        """

        let snap = try ClaudeStatusProbe.parse(text: sample)
        #expect(snap.weeklyPercentLeft == nil)
        #expect(snap.extraRateWindows.map(\.title) == ["Haiku only"])
    }

    @Test
    func `heavier corruption stays a visible scoped row`() throws {
        // "almdls" is edit distance 3 from "allmodels" — beyond the tolerance. We intentionally do
        // NOT absorb it into Weekly (that would risk swallowing a real future scoped model); instead
        // it stays visible as its own row so nothing is silently dropped.
        let sample = """
         Current session
         ▌                                                  0% used
         Resets 1:10pm (Asia/Seoul)

         Current week (almdls)
         █████████████████████████████████▌                66% used
         Resets Jul 24 at 2pm (Asia/Seoul)
        """

        let snap = try ClaudeStatusProbe.parse(text: sample)
        #expect(snap.weeklyPercentLeft == nil)
        #expect(snap.extraRateWindows.map(\.title) == ["almdls only"])
    }
}
