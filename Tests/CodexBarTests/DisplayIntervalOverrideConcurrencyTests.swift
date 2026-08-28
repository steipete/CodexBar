import Foundation
import Testing
@testable import CodexBarCore

private actor DisplayIntervalOverrideBarrier {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
            guard self.continuations.count == 2 else { return }

            let continuations = self.continuations
            self.continuations.removeAll()
            continuations.forEach { $0.resume() }
        }
    }
}

private struct ObservedDisplayIntervals: Hashable {
    let staleness: TimeInterval
    let unavailableRetry: TimeInterval
}

struct DisplayIntervalOverrideConcurrencyTests {
    @Test
    func `concurrent display interval override scopes remain isolated`() async {
        let expected = [
            ObservedDisplayIntervals(staleness: 0.1, unavailableRetry: 0.2),
            ObservedDisplayIntervals(staleness: 0.3, unavailableRetry: 0.4),
        ]
        let barrier = DisplayIntervalOverrideBarrier()

        let observed = await withTaskGroup(
            of: ObservedDisplayIntervals.self,
            returning: Set<ObservedDisplayIntervals>.self)
        { group in
            for intervals in expected {
                group.addTask {
                    await CookieHeaderCache.withDisplayStalenessIntervalOverrideForTesting(intervals.staleness) {
                        await CookieHeaderCache.withDisplayUnavailableRetryIntervalOverrideForTesting(
                            intervals.unavailableRetry)
                        {
                            await barrier.wait()
                            return await Task {
                                let current = CookieHeaderCache.displayIntervalsForTesting()
                                return ObservedDisplayIntervals(
                                    staleness: current.staleness,
                                    unavailableRetry: current.unavailableRetry)
                            }.value
                        }
                    }
                }
            }

            var values: Set<ObservedDisplayIntervals> = []
            for await value in group {
                values.insert(value)
            }
            return values
        }

        #expect(observed == Set(expected))
    }
}
