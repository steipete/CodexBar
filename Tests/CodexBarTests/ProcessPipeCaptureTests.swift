import Darwin
import Foundation
import Testing
@testable import CodexBarCore

struct ProcessPipeCaptureTests {
    @Test
    func `finish followed by deferred stop closes the handle only once`() {
        let handle = CountingFileHandle()
        let capture = ProcessPipeCapture(handle: handle)
        do {
            defer { capture.stop() }
            #expect(capture.finishSynchronously(timeout: 0).isEmpty)
        }
        DispatchQueue.concurrentPerform(iterations: 8) { _ in capture.stop() }
        #expect(handle.closeCount == 1)
    }

    @Test
    func `concurrent finish waits for the owning teardown`() throws {
        let handle = CountingFileHandle()
        let closeStarted = DispatchSemaphore(value: 0)
        let releaseClose = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let finishers = DispatchGroup()
        handle.beforeFirstClose = {
            closeStarted.signal()
            releaseClose.wait()
        }
        let capture = ProcessPipeCapture(handle: handle)
        defer {
            releaseClose.signal()
            #expect(finishers.wait(timeout: .now() + 10) == .success)
        }
        finishers.enter()
        DispatchQueue.global().async {
            _ = capture.finishSynchronously(timeout: 0)
            finishers.leave()
        }
        try #require(closeStarted.wait(timeout: .now() + 10) == .success)
        finishers.enter()
        DispatchQueue.global().async {
            secondStarted.signal()
            _ = capture.finishSynchronously(timeout: 0)
            secondFinished.signal()
            finishers.leave()
        }
        try #require(secondStarted.wait(timeout: .now() + 10) == .success)
        #expect(secondFinished.wait(timeout: .now() + 0.1) == .timedOut)
        releaseClose.signal()
        #expect(finishers.wait(timeout: .now() + 10) == .success)
        #expect(handle.closeCount == 1)
    }

    @Test
    func `finish then stop preserves output during descriptor reuse`() {
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            for _ in 0..<1000 {
                autoreleasepool {
                    let pipe = Pipe()
                    let capture = ProcessPipeCapture(pipe: pipe)
                    capture.start()
                    defer { capture.stop() }
                    pipe.fileHandleForWriting.write(Data([65]))
                    pipe.fileHandleForWriting.closeFile()
                    #expect(capture.finishSynchronously(timeout: 5) == Data([65]))
                    let reused = open("/dev/null", O_RDONLY)
                    defer { close(reused) }
                    capture.stop()
                    #expect(fcntl(reused, F_GETFD) != -1)
                }
            }
        }
    }
}

private final class CountingFileHandle: FileHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var closes = 0
    var beforeFirstClose: (@Sendable () -> Void)?

    var closeCount: Int {
        self.lock.withLock { self.closes }
    }

    override var readabilityHandler: (@Sendable (FileHandle) -> Void)? {
        get { nil }
        set {}
    }

    override func close() throws {
        let firstClose = self.lock.withLock {
            self.closes += 1
            return self.closes == 1
        }
        if firstClose { self.beforeFirstClose?() }
    }
}
