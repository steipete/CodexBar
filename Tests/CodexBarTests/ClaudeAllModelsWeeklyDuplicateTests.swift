import CodexBarCore
import Foundation
import Testing

/// The Claude CLI renders /usage as a redrawing TUI, so a half-painted capture frame can drop a
/// character from "Current week (all models)" (-> "all modls"). These cover both shapes: the
/// garbled copy must not become a bogus second weekly row, and if it is the only surviving
/// all-models line the Weekly limit must still be recovered from it.
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
        // Only the genuine model-scoped window (Fable) survives; the garbled all-models copy is dropped.
        let titles = snap.extraRateWindows.map(\.title)
        #expect(titles == ["Fable only"], "unexpected scoped weekly rows: \(titles)")
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
    func `genuine scoped model is not swallowed by the tolerant match`() throws {
        let sample = """
         Current session
         ▌                                                  0% used
         Resets 1:10pm (Asia/Seoul)

         Current week (all models)
         █▌                                                 66% used
         Resets Jul 24 at 2pm (Asia/Seoul)

         Current week (Sonnet only)
         █▌                                                 10% used
         Resets Jul 24 at 2pm (Asia/Seoul)
        """

        let snap = try ClaudeStatusProbe.parse(text: sample)
        #expect(snap.weeklyPercentLeft == 34)
        #expect(snap.opusPercentLeft == 90)
    }
}
