import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct GrokWeeklyResetDetectorTests {
    private func posts(_ samples: [(Double, String, String)]) -> [String] {
        let formatter = ISO8601DateFormatter()
        var state: UsageStore.LimitResetDetectorState?
        var posts: [String] = []
        for (used, at, resetsAt) in samples {
            let snapshot = UsageSnapshot(
                primary: RateWindow(
                    usedPercent: used,
                    windowMinutes: 10080,
                    resetsAt: formatter.date(from: resetsAt)!,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: formatter.date(from: at)!)
            let transition = UsageStore
                .limitResetDetectorTransition(input: UsageStore.LimitResetDetectorTransitionInput(
                    provider: UsageProvider.grok.instanceID,
                    snapshot: snapshot,
                    seriesName: .weekly,
                    observation: UsageStore.LimitResetObservation(
                        usedPercent: used,
                        observedAt: formatter.date(from: at)!,
                        resetBoundary: formatter.date(from: resetsAt)!,
                        source: nil),
                    previousState: state,
                    requiresLowConfirmation: false))
            if transition.shouldPost { posts.append(at) }
            state = transition.state
        }
        return posts
    }

    @Test
    func `replaying flipped Grok weekly samples posts no reset`() {
        let current = "2026-11-05T01:24:54Z"
        let other = "2026-11-09T05:19:10Z"
        let samples: [(Double, String, String)] = [
            (84, "2026-11-02T07:08:40Z", current), (0, "2026-11-02T07:08:43Z", other),
            (97, "2026-11-02T18:59:50Z", current), (0, "2026-11-03T01:42:51Z", other),
            (100, "2026-11-03T01:59:51Z", current), (100, "2026-11-03T02:00:52Z", current),
            (0, "2026-11-03T02:01:49Z", other), (100, "2026-11-03T02:06:51Z", other),
            (0, "2026-11-03T02:07:51Z", other),
        ]
        #expect(self.posts(samples).isEmpty)
    }

    @Test
    func `genuine Grok weekly reset posts once`() {
        let samples: [(Double, String, String)] = [
            (100, "2026-10-29T01:24:39Z", "2026-10-29T01:24:54Z"),
            (1, "2026-10-29T01:59:39Z", "2026-11-05T01:24:54Z"),
        ]
        #expect(self.posts(samples) == ["2026-10-29T01:59:39Z"])
    }

    @Test
    func `advanced boundary from a still-high sample does not steal the later reset`() {
        let samples: [(Double, String, String)] = [
            (100, "2026-10-29T01:24:39Z", "2026-10-29T01:24:54Z"),
            (100, "2026-10-29T01:30:00Z", "2026-11-05T01:24:54Z"),
            (1, "2026-10-29T01:59:39Z", "2026-11-05T01:24:54Z"),
        ]
        #expect(self.posts(samples) == ["2026-10-29T01:59:39Z"])
    }

    @Test
    func `initial transient low boundary is rebaselined by later high samples`() {
        let samples: [(Double, String, String)] = [
            (0, "2026-11-02T07:08:43Z", "2026-11-09T05:19:10Z"),
            (97, "2026-11-02T18:59:50Z", "2026-11-05T01:24:54Z"),
            (1, "2026-11-05T02:00:00Z", "2026-11-12T01:24:54Z"),
        ]
        #expect(self.posts(samples) == ["2026-11-05T02:00:00Z"])
    }
}
