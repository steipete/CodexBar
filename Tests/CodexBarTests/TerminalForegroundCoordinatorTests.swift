import Foundation
import Testing
@testable import CodexBarCore

struct TerminalForegroundCoordinatorTests {
    @Test
    func `leases serialize overlapping probes`() {
        let coordinator = TerminalForegroundCoordinator()
        let state = TerminalForegroundTestState(initialProcessGroup: 100)
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondAttempted = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()

        finished.enter()
        DispatchQueue.global().async {
            let lease = coordinator.acquire(isTerminal: true) { state.capture() }
            state.setProcessGroup(101)
            firstEntered.signal()
            releaseFirst.wait()
            coordinator.release(lease) { state.restore($0) }
            finished.leave()
        }

        #expect(firstEntered.wait(timeout: .now() + 1) == .success)

        finished.enter()
        DispatchQueue.global().async {
            secondAttempted.signal()
            let lease = coordinator.acquire(isTerminal: true) { state.capture() }
            secondEntered.signal()
            state.setProcessGroup(102)
            coordinator.release(lease) { state.restore($0) }
            finished.leave()
        }

        #expect(secondAttempted.wait(timeout: .now() + 1) == .success)
        #expect(secondEntered.wait(timeout: .now() + 0.1) == .timedOut)
        releaseFirst.signal()
        #expect(secondEntered.wait(timeout: .now() + 1) == .success)
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(state.capturedProcessGroups == [100, 100])
        #expect(state.currentProcessGroup == 100)
    }

    @Test
    func `non-terminal leases bypass capture and restoration`() {
        let coordinator = TerminalForegroundCoordinator()
        var didCapture = false
        var didRestore = false

        let lease = coordinator.acquire(isTerminal: false) {
            didCapture = true
            return 100
        }
        coordinator.release(lease) { _ in didRestore = true }

        #expect(didCapture == false)
        #expect(didRestore == false)
    }
}

private final class TerminalForegroundTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var processGroup: pid_t
    private var captures: [pid_t] = []

    init(initialProcessGroup: pid_t) {
        self.processGroup = initialProcessGroup
    }

    var capturedProcessGroups: [pid_t] {
        self.lock.withLock { self.captures }
    }

    var currentProcessGroup: pid_t {
        self.lock.withLock { self.processGroup }
    }

    func capture() -> pid_t {
        self.lock.withLock {
            self.captures.append(self.processGroup)
            return self.processGroup
        }
    }

    func setProcessGroup(_ value: pid_t) {
        self.lock.withLock { self.processGroup = value }
    }

    func restore(_ value: pid_t?) {
        guard let value else { return }
        self.setProcessGroup(value)
    }
}
