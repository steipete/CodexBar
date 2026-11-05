import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct GrokWeeklyResetDetectorTests {
    private func posts(
        _ samples: [(Double, String, String)],
        initialState: UsageStore.LimitResetDetectorState? = nil) throws -> [String]
    {
        let formatter = ISO8601DateFormatter()
        var state = initialState
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
            state = try JSONDecoder().decode(
                UsageStore.LimitResetDetectorState.self,
                from: JSONEncoder().encode(transition.state))
        }
        return posts
    }

    @Test
    func `replaying flipped Grok weekly samples posts no reset`() throws {
        let current = "2026-11-05T01:24:54Z"
        let other = "2026-11-09T05:19:10Z"
        let samples: [(Double, String, String)] = [
            (84, "2026-11-02T07:08:40Z", current), (0, "2026-11-02T07:08:43Z", other),
            (97, "2026-11-02T18:59:50Z", current), (0, "2026-11-03T01:42:51Z", other),
            (100, "2026-11-03T01:59:51Z", current), (100, "2026-11-03T02:00:52Z", current),
            (0, "2026-11-03T02:01:49Z", other), (100, "2026-11-03T02:06:51Z", other),
            (0, "2026-11-03T02:07:51Z", other),
        ]
        #expect(try self.posts(samples).isEmpty)
    }

    @Test
    func `genuine Grok weekly reset posts once`() throws {
        let samples: [(Double, String, String)] = [
            (100, "2026-10-29T01:24:39Z", "2026-10-29T01:24:54Z"),
            (1, "2026-10-29T01:59:39Z", "2026-11-05T01:24:54Z"),
        ]
        #expect(try self.posts(samples) == ["2026-10-29T01:59:39Z"])
    }

    @Test
    func `advanced boundary from a still-high sample does not steal the later reset`() throws {
        let samples: [(Double, String, String)] = [
            (100, "2026-10-29T01:24:39Z", "2026-10-29T01:24:54Z"),
            (100, "2026-10-29T01:30:00Z", "2026-11-05T01:24:54Z"),
            (1, "2026-10-29T01:59:39Z", "2026-11-05T01:24:54Z"),
        ]
        #expect(try self.posts(samples) == ["2026-10-29T01:59:39Z"])
    }

    @Test
    func `initial transient low boundary is rebaselined by later high samples`() throws {
        let samples: [(Double, String, String)] = [
            (0, "2026-11-02T07:08:43Z", "2026-11-09T05:19:10Z"),
            (97, "2026-11-02T18:59:50Z", "2026-11-05T01:24:54Z"),
            (1, "2026-11-05T02:00:00Z", "2026-11-12T01:24:54Z"),
        ]
        #expect(try self.posts(samples) == ["2026-11-05T02:00:00Z"])
    }

    @Test
    func `early low waits until the exact weekly boundary`() throws {
        let samples: [(Double, String, String)] = [
            (100, "2026-10-29T01:24:00Z", "2026-10-29T01:24:54Z"),
            (0, "2026-10-29T01:24:24Z", "2026-11-05T01:24:54Z"),
            (0, "2026-10-29T01:24:54Z", "2026-11-05T01:24:54Z"),
        ]
        #expect(try self.posts(samples) == ["2026-10-29T01:24:54Z"])
    }

    @Test
    func `stale samples cannot rewind a confirmed period or steal the next reset`() throws {
        let samples: [(Double, String, String)] = [
            (100, "2026-10-29T01:24:00Z", "2026-10-29T01:24:54Z"),
            (0, "2026-10-29T01:25:00Z", "2026-11-05T01:24:54Z"),
            (100, "2026-10-30T01:00:00Z", "2026-10-29T01:24:54Z"),
            (0, "2026-10-30T01:01:00Z", "2026-11-09T05:19:10Z"),
            (100, "2026-11-05T01:24:00Z", "2026-11-05T01:24:54Z"),
            (0, "2026-11-05T01:25:00Z", "2026-11-12T01:24:54Z"),
        ]
        #expect(try self.posts(samples) == ["2026-10-29T01:25:00Z", "2026-11-05T01:25:00Z"])
    }

    @Test
    func `legacy phantom post does not prevent rebaselining and a genuine reset`() throws {
        let formatter = ISO8601DateFormatter()
        let phantom = try #require(formatter.date(from: "2026-11-09T05:19:10Z"))
        let legacy = try UsageStore.LimitResetDetectorState(
            wasAboveThreshold: false,
            lastObservedAt: #require(formatter.date(from: "2026-11-03T02:07:51Z")),
            sourceRawValue: nil,
            resetBoundary: phantom,
            lastPostedResetBoundary: phantom)
        let persisted = try JSONDecoder().decode(
            UsageStore.LimitResetDetectorState.self,
            from: JSONEncoder().encode(legacy))
        let samples: [(Double, String, String)] = [
            (100, "2026-11-04T01:00:00Z", "2026-11-05T01:24:54Z"),
            (0, "2026-11-05T01:25:00Z", "2026-11-12T01:24:54Z"),
        ]
        #expect(try self.posts(samples, initialState: persisted) == ["2026-11-05T01:25:00Z"])
    }
}
