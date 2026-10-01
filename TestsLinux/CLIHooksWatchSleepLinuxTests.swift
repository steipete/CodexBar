import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIHooksWatchSleepLinuxTests {
    @Test
    func `already requested stop skips every sleep tick`() async {
        let stop = HooksWatchStopSignal()
        stop.request()

        await CodexBarCLI.sleepInterruptibly(interval: 30, stop: stop) { _ in
            Issue.record("An already requested stop must not sleep")
        }
    }

    @Test
    func `stop requested during a tick prevents the next sleep`() async {
        // The signal monitor flips the flag without cancelling this task. Record the
        // requested ticks so a single full-interval sleep cannot satisfy this test.
        let stop = HooksWatchStopSignal()
        var ticks: [UInt64] = []
        await CodexBarCLI.sleepInterruptibly(interval: 10, stop: stop) { nanoseconds in
            ticks.append(nanoseconds)
            stop.request()
        }

        #expect(ticks == [200_000_000])
    }

    @Test(arguments: [0.0, -1.0, 0.05, 0.4, 0.45])
    func `unsignaled sleep requests the full interval in bounded ticks`(interval: TimeInterval) async {
        let stop = HooksWatchStopSignal()
        var ticks: [UInt64] = []
        await CodexBarCLI.sleepInterruptibly(interval: interval, stop: stop) { nanoseconds in
            ticks.append(nanoseconds)
        }

        let expected = UInt64((max(0, interval) * 1_000_000_000).rounded())
        #expect(ticks.reduce(0, +) == expected)
        #expect(ticks.allSatisfy { $0 > 0 && $0 <= 200_000_000 })
        #expect(ticks.count == Int((expected + 199_999_999) / 200_000_000))
    }
}
