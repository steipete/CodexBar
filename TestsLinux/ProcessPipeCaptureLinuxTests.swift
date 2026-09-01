import Foundation
#if os(Linux)
import Glibc
#endif
import Testing
@testable import CodexBarCore

#if os(Linux)
@Suite(.serialized)
struct ProcessPipeCaptureLinuxTests {
    private static let emfileChildEnvironmentKey = "CODEXBAR_PROCESS_PIPE_EMFILE_CHILD"

    @Test
    func `blocked onData callback does not block capture close`() throws {
        let callbackStarted = DispatchSemaphore(value: 0)
        let callbackFinished = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let closeStarted = DispatchSemaphore(value: 0)
        let closeFinished = DispatchGroup()
        let state = BlockedCallbackCloseState()
        let pipe = Pipe()
        let capture = ProcessPipeCapture(pipe: pipe, onData: {
            defer { callbackFinished.signal() }
            guard state.beginCallback() else { return }
            callbackStarted.signal()
            releaseCallback.wait()
        })
        closeFinished.enter()
        let readinessDeadline = DispatchTime.now() + 1
        let closer = Thread {
            defer { closeFinished.leave() }
            let measuring = state.beginClose(before: readinessDeadline)
            if measuring { closeStarted.signal() }
            // A late worker still cleans up the capture without acknowledging an abandoned scenario.
            _ = capture.finishSynchronously(timeout: 0.05)
            if measuring { state.recordCloseReturn() }
        }
        var closerLaunched = false
        defer {
            let callbackEntered = state.abandon()
            releaseCallback.signal()
            do {
                try pipe.fileHandleForWriting.close()
            } catch {
                Issue.record(error, "Writer cleanup failed; \(state.diagnostic)")
            }
            let cleanupDeadline = DispatchTime.now() + 1
            if !closerLaunched { closer.start() }
            #expect(
                closeFinished.wait(timeout: cleanupDeadline) == .success,
                "Close worker cleanup did not finish; \(state.diagnostic)")
            if callbackEntered {
                #expect(
                    callbackFinished.wait(timeout: cleanupDeadline) == .success,
                    "Callback cleanup did not finish; \(state.diagnostic)")
            }
        }

        capture.start()
        try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
        try #require(
            callbackStarted.wait(timeout: readinessDeadline) == .success,
            "Callback readiness expired; \(state.diagnostic)")

        closerLaunched = true
        closer.start()
        try #require(
            closeStarted.wait(timeout: readinessDeadline) == .success,
            "Close worker entry exceeded shared readiness budget; \(state.diagnostic)")
        try #require(
            closeFinished.wait(timeout: .now() + 0.5) == .success,
            "Close did not finish while the callback was blocked; \(state.diagnostic)")
        let elapsed = try #require(state.invocationDuration, "Missing close timing; \(state.diagnostic)")
        #expect(elapsed < .milliseconds(500), "Close invocation exceeded 500 ms; \(state.diagnostic)")
    }

    @Test
    func `continuous output does not defeat the capture timeout`() throws {
        let writerStarted = DispatchSemaphore(value: 0)
        let stopWriter = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let pipe = Pipe()
        let writerDescriptor = pipe.fileHandleForWriting.fileDescriptor
        let writerFlags = Glibc.fcntl(writerDescriptor, F_GETFL)
        #expect(writerFlags >= 0)
        #expect(Glibc.fcntl(writerDescriptor, F_SETFL, writerFlags | O_NONBLOCK) == 0)

        let capture = ProcessPipeCapture(pipe: pipe, maxBytes: 1024)
        capture.start()
        DispatchQueue.global().async {
            var blockedSignals = sigset_t()
            var previousSignals = sigset_t()
            Glibc.sigemptyset(&blockedSignals)
            Glibc.sigaddset(&blockedSignals, SIGPIPE)
            _ = Glibc.pthread_sigmask(SIG_BLOCK, &blockedSignals, &previousSignals)
            defer {
                var pendingSignals = sigset_t()
                if Glibc.sigpending(&pendingSignals) == 0, Glibc.sigismember(&pendingSignals, SIGPIPE) == 1 {
                    var noWait = timespec(tv_sec: 0, tv_nsec: 0)
                    _ = Glibc.sigtimedwait(&blockedSignals, nil, &noWait)
                }
                _ = Glibc.pthread_sigmask(SIG_SETMASK, &previousSignals, nil)
            }

            var bytes = [UInt8](repeating: 0x41, count: 16 * 1024)
            while stopWriter.wait(timeout: .now()) == .timedOut {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Glibc.write(writerDescriptor, buffer.baseAddress, buffer.count)
                }
                if count < 0, errno == EPIPE {
                    break
                }
                if count > 0 {
                    writerStarted.signal()
                }
            }
            writerFinished.signal()
        }
        #expect(writerStarted.wait(timeout: .now() + 1) == .success)

        let startedAt = ContinuousClock.now
        _ = capture.finishSynchronously(timeout: 0.01)
        let elapsed = startedAt.duration(to: .now)
        stopWriter.signal()

        #expect(elapsed < .milliseconds(500))
        #expect(writerFinished.wait(timeout: .now() + 1) == .success)
        try pipe.fileHandleForWriting.close()
    }

    @Test
    func `Linux descriptor setup failure closes the read end immediately`() throws {
        let pipe = Pipe()
        let capture = ProcessPipeCapture(pipe: pipe)
        capture.start(linuxDescriptorSetup: { descriptor in
            errno = EMFILE
            return descriptor < 0
        })

        // Descriptor numbers can be reused as soon as close returns. POLLERR on this pipe's write end proves
        // the original pipe has no remaining reader without assuming its former descriptor stays unused.
        var writerPollDescriptor = pollfd(
            fd: pipe.fileHandleForWriting.fileDescriptor,
            events: 0,
            revents: 0)
        #expect(Glibc.poll(&writerPollDescriptor, 1, 0) == 1)
        #expect(writerPollDescriptor.revents & Int16(POLLERR) != 0)

        let startedAt = ContinuousClock.now
        let data = capture.finishSynchronously(timeout: 5)
        let elapsed = startedAt.duration(to: .now)

        #expect(data.isEmpty)
        #expect(elapsed < .milliseconds(500))
        try pipe.fileHandleForWriting.close()
    }

    @Test
    func `capture starts while the process is at EMFILE`() throws {
        if ProcessInfo.processInfo.environment[Self.emfileChildEnvironmentKey] == "1" {
            try Self.runEMFILEChildScenario()
            return
        }

        let process = Process()
        let testExecutable = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        process.executableURL = URL(fileURLWithPath: testExecutable)
        process.arguments = ["--filter", "ProcessPipeCaptureLinuxTests", "--testing-library", "swift-testing"]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.emfileChildEnvironmentKey] = "1"
        process.environment = environment
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }

    @Test
    func `ProcessPipeCapture releases its pipe read end after capture`() throws {
        let initialFDs = try countOpenFDs()
        for _ in 0..<100 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/echo")
            proc.arguments = ["hello"]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice

            let capture = ProcessPipeCapture(pipe: out)
            capture.start()
            try proc.run()
            try out.fileHandleForWriting.close()
            proc.waitUntilExit()
            let data = capture.finishSynchronously(timeout: 0.25)
            #expect(String(decoding: data, as: UTF8.self) == "hello\n")
        }
        let finalFDs = try countOpenFDs()

        // Allow a small tolerance for unrelated fd churn, but ensure we are
        // not leaking pipe read ends (which would show as ~100 extra fds).
        #expect(finalFDs - initialFDs <= 15)
    }

    private static func runEMFILEChildScenario() throws {
        var originalLimit = rlimit()
        let noFileResource = Int32(RLIMIT_NOFILE.rawValue)
        #expect(Glibc.getrlimit(noFileResource, &originalLimit) == 0)

        let pipe = Pipe()
        let capture = ProcessPipeCapture(pipe: pipe)
        let highestOpenFileDescriptor = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
            .compactMap(Int.init)
            .max() ?? 32
        var constrainedLimit = originalLimit
        constrainedLimit.rlim_cur = min(originalLimit.rlim_cur, rlim_t(highestOpenFileDescriptor + 32))
        #expect(Glibc.setrlimit(noFileResource, &constrainedLimit) == 0)

        var heldFileDescriptors: [Int32] = []
        defer {
            for descriptor in heldFileDescriptors {
                Glibc.close(descriptor)
            }
            _ = Glibc.setrlimit(noFileResource, &originalLimit)
        }
        while true {
            let descriptor = Glibc.dup(STDIN_FILENO)
            if descriptor < 0 {
                #expect(errno == EMFILE)
                break
            }
            heldFileDescriptors.append(descriptor)
        }

        capture.start()
        try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
        try pipe.fileHandleForWriting.close()
        let data = capture.finishSynchronously(timeout: 1)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
        #expect(capture.reachedEOF)
    }
}

/// All callback/closer state is protected by the lock; only the test thread launches the closer.
private final class BlockedCallbackCloseState: @unchecked Sendable {
    private let lock = NSLock()
    private var abandoned = false
    private var callbackEntered = false
    private var startedAt: ContinuousClock.Instant?
    private var returnedAt: ContinuousClock.Instant?

    func beginCallback() -> Bool {
        self.lock.withLock {
            guard !self.abandoned else { return false }
            self.callbackEntered = true
            return true
        }
    }

    func beginClose(before deadline: DispatchTime) -> Bool {
        self.lock.withLock {
            guard !self.abandoned, DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds else {
                return false
            }
            self.startedAt = .now
            return true
        }
    }

    func recordCloseReturn() {
        let returnedAt = ContinuousClock.now
        self.lock.withLock { self.returnedAt = returnedAt }
    }

    func abandon() -> Bool {
        self.lock.withLock {
            self.abandoned = true
            return self.callbackEntered
        }
    }

    var invocationDuration: Duration? {
        self.lock.withLock {
            guard let startedAt = self.startedAt, let returnedAt = self.returnedAt else { return nil }
            return startedAt.duration(to: returnedAt)
        }
    }

    var diagnostic: String {
        self.lock.withLock {
            let elapsed = self.startedAt.map { $0.duration(to: self.returnedAt ?? .now) }
            return "callbackEntered=\(self.callbackEntered), abandoned=\(self.abandoned), " +
                "closeEntered=\(self.startedAt != nil), closeReturned=\(self.returnedAt != nil), " +
                "closeElapsed=\(String(describing: elapsed))"
        }
    }
}

private func countOpenFDs() throws -> Int {
    let entries = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
    return entries.count
}
#endif
