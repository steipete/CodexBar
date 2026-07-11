import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ShellCommandForegroundTests {
    @Test
    func `restore rejects stale and unrelated process groups`() {
        #expect(ShellCommandLocator.test_terminalForegroundRestoreTarget(
            original: 100,
            probe: 200,
            current: 200) == 100)
        #expect(ShellCommandLocator.test_terminalForegroundRestoreTarget(
            original: 100,
            probe: 200,
            current: 100) == nil)
        #expect(ShellCommandLocator.test_terminalForegroundRestoreTarget(
            original: 100,
            probe: 200,
            current: 300) == nil)
        #expect(ShellCommandLocator.test_terminalForegroundRestoreTarget(
            original: 100,
            probe: nil,
            current: 200) == nil)
    }

    @Test
    func `foreground probes are serialized`() {
        let coordinator = TerminalForegroundProbeCoordinator()
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()

        finished.enter()
        DispatchQueue.global().async {
            coordinator.withLock {
                firstEntered.signal()
                _ = releaseFirst.wait(timeout: .now() + 5)
            }
            finished.leave()
        }
        #expect(firstEntered.wait(timeout: .now() + 5) == .success)

        finished.enter()
        DispatchQueue.global().async {
            secondStarted.signal()
            _ = coordinator.withLock {
                secondEntered.signal()
            }
            finished.leave()
        }
        #expect(secondStarted.wait(timeout: .now() + 5) == .success)
        #expect(secondEntered.wait(timeout: .now() + 0.1) == .timedOut)

        releaseFirst.signal()
        #expect(secondEntered.wait(timeout: .now() + 5) == .success)
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }
}
