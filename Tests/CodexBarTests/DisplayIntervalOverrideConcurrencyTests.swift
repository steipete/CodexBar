import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct DisplayIntervalOverrideConcurrencyTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_TSAN_STRESS"] == "1"))
    func `concurrent display-interval override writes and reads are race-free`() {
        defer {
            CookieHeaderCache.setDisplayStalenessIntervalOverrideForTesting(nil)
            CookieHeaderCache.setDisplayUnavailableRetryIntervalOverrideForTesting(nil)
        }
        let iterations = 5000
        let lanes = 4
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "display-interval-override.concurrency", attributes: .concurrent)
        for lane in 0..<lanes {
            group.enter()
            queue.async {
                for i in 0..<iterations {
                    if (lane + i) % 2 == 0 {
                        CookieHeaderCache.setDisplayStalenessIntervalOverrideForTesting(TimeInterval(i))
                        CookieHeaderCache.setDisplayUnavailableRetryIntervalOverrideForTesting(TimeInterval(i))
                    } else {
                        _ = CookieHeaderCache.displayIntervalsForTesting()
                    }
                }
                group.leave()
            }
        }
        group.wait()
    }
}
