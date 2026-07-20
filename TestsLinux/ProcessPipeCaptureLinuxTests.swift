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
        let releaseCallback = DispatchSemaphore(value: 0)
        let captureFinished = DispatchSemaphore(value: 0)
        let pipe = Pipe()
        let capture = ProcessPipeCapture(pipe: pipe, onData: {
            callbackStarted.signal()
            releaseCallback.wait()
        })
        capture.start()

        try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
        #expect(callbackStarted.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            _ = capture.finishSynchronously(timeout: 0.05)
            captureFinished.signal()
        }
        let finishResult = captureFinished.wait(timeout: .now() + 0.5)
        releaseCallback.signal()
        #expect(finishResult == .success)
        if finishResult != .success {
            _ = captureFinished.wait(timeout: .now() + 1)
        }
        try pipe.fileHandleForWriting.close()
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
        let readFileDescriptor = pipe.fileHandleForReading.fileDescriptor
        let capture = ProcessPipeCapture(pipe: pipe)
        capture.start(linuxDescriptorSetup: { descriptor in
            errno = EMFILE
            return descriptor < 0
        })

        let startedAt = ContinuousClock.now
        let data = capture.finishSynchronously(timeout: 5)
        let elapsed = startedAt.duration(to: .now)

        #expect(data.isEmpty)
        #expect(elapsed < .milliseconds(500))
        #expect(Glibc.fcntl(readFileDescriptor, F_GETFD) == -1)
        #expect(errno == EBADF)
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

private func countOpenFDs() throws -> Int {
    let entries = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")
    return entries.count
}
#endif
