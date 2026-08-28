import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIHooksWatchSleepLinuxTests {
    @Test
    func `returns quickly when stop already requested`() async {
        let stop = HooksWatchStopSignal()
        stop.request()

        let start = DispatchTime.now()
        await CodexBarCLI.sleepInterruptibly(interval: 30, stop: stop)
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

        #expect(elapsedSeconds < 1)
    }

    @Test
    func `stops promptly when signaled mid sleep`() async {
        // Regression: CLITerminationSignalMonitor only flips a flag, it does not
        // cancel the running task. A single long Task.sleep would leave `hooks
        // watch` appearing hung on SIGINT until the full interval elapsed.
        let stop = HooksWatchStopSignal()
        Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000)
            stop.request()
        }

        let start = DispatchTime.now()
        await CodexBarCLI.sleepInterruptibly(interval: 10, stop: stop)
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

        // The 0.3s signal must interrupt the 10s interval promptly; allow headroom for loaded
        // CI runners (observed 2.02s on x64 under contention).
        #expect(elapsedSeconds < 5)
    }

    @Test
    func `sleeps the full interval when never signaled`() async {
        let stop = HooksWatchStopSignal()
        let start = DispatchTime.now()
        await CodexBarCLI.sleepInterruptibly(interval: 0.4, stop: stop)
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

        #expect(elapsedSeconds >= 0.35)
    }
}
