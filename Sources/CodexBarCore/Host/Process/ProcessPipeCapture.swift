import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

package final class ProcessPipeCapture: @unchecked Sendable {
    package static let defaultMaxBytes = 1 * 1024 * 1024

    private let handle: FileHandle
    private let onData: (@Sendable () -> Void)?
    private let maxBytes: Int
    private let condition = NSCondition()
    private var data = Data()
    private var activeCallbacks = 0
    private var isFinished = false
    private var didReachEOF = false
    private var isStopping = false
    private var continuation: CheckedContinuation<Void, Never>?
    #if os(Linux)
    private let callbackQueue = DispatchQueue(label: "com.steipete.CodexBar.process-pipe-capture.callback")
    private var readerStarted = false
    private var readerExited = false
    private var callbackScheduled = false
    private var callbackRequested = false
    #endif

    package init(
        pipe: Pipe,
        maxBytes: Int = ProcessPipeCapture.defaultMaxBytes,
        onData: (@Sendable () -> Void)? = nil)
    {
        self.handle = pipe.fileHandleForReading
        self.maxBytes = max(0, maxBytes)
        self.onData = onData
    }

    package func start() {
        #if os(Linux)
        self.start(linuxDescriptorSetup: Self.makeNonBlocking)
        #else
        self.installReadabilityHandler()
        #endif
    }

    #if os(Linux)
    package func start(linuxDescriptorSetup: @Sendable (Int32) -> Bool) {
        self.condition.lock()
        guard !self.readerStarted, !self.isFinished, !self.isStopping else {
            self.condition.unlock()
            return
        }
        self.readerStarted = true
        self.condition.unlock()

        let fileDescriptor = self.handle.fileDescriptor
        guard linuxDescriptorSetup(fileDescriptor) else {
            self.finishFailedLinuxStart()
            return
        }

        // FileHandle.readabilityHandler duplicates the descriptor on Linux and traps if dup(2) returns EMFILE.
        // DispatchSourceRead avoids that duplication, but Swift 6.3's Linux epoll backend can unregister and free
        // a pipe's shared muxnote on its target queue while the manager queue is still traversing the HUP event.
        // Poll on an owned thread instead: the reader keeps sole descriptor-close ownership, while the bounded poll
        // interval keeps stop() responsive without allocating a wakeup descriptor that would break the EMFILE path.
        Thread.detachNewThread { [self] in
            Thread.current.name = "CodexBar pipe capture"
            self.runLinuxReader(fileDescriptor: fileDescriptor)
        }
    }
    #endif

    package func finish(timeout: Duration) async -> Data {
        let drainTask = Task<Void, Error> {
            await self.waitUntilFinished()
        }
        let join = BoundedTaskJoin(sourceTask: drainTask)
        _ = await join.value(joinGrace: timeout)
        return self.stopAndSnapshot()
    }

    package func finishSynchronously(timeout: TimeInterval) -> Data {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        self.condition.lock()
        while !self.isFinished, !self.isStopping {
            guard self.condition.wait(until: deadline) else { break }
        }
        self.condition.unlock()
        return self.stopAndSnapshot()
    }

    /// Waits only for the first complete output line. Useful for helpers whose descendants may inherit stdout
    /// after the helper itself exits, preventing EOF even though the caller already has its complete answer.
    package func finishFirstLineSynchronously(timeout: TimeInterval) -> Data {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        self.condition.lock()
        while !self.isFinished, !self.isStopping, !self.data.contains(0x0A) {
            guard self.condition.wait(until: deadline) else { break }
        }
        self.condition.unlock()
        return self.stopAndSnapshot()
    }

    package func stop() {
        _ = self.stopAndSnapshot()
    }

    package var reachedEOF: Bool {
        self.condition.lock()
        defer { self.condition.unlock() }
        return self.didReachEOF
    }

    /// Snapshot of the bytes captured so far, without stopping the capture. Lets a caller
    /// poll for interactive output (e.g. a device-flow URL/code) while the process is still running.
    package func currentSnapshot() -> Data {
        self.condition.lock()
        defer { self.condition.unlock() }
        return self.data
    }

    package static func decodeUTF8(_ data: Data) -> String {
        // A byte cap can split the final scalar; lossy decoding preserves the valid captured prefix.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data, as: UTF8.self)
    }

    private func handleReadableData(from handle: FileHandle) {
        self.condition.lock()
        guard !self.isStopping else {
            self.condition.unlock()
            return
        }
        self.activeCallbacks += 1
        self.condition.unlock()

        let chunk = handle.availableData
        var continuation: CheckedContinuation<Void, Never>?

        self.condition.lock()
        if chunk.isEmpty {
            self.isFinished = true
            self.didReachEOF = true
            continuation = self.continuation
            self.continuation = nil
        } else {
            let remainingBytes = max(0, self.maxBytes - self.data.count)
            if remainingBytes > 0 {
                self.data.append(chunk.prefix(remainingBytes))
            }
        }
        self.activeCallbacks -= 1
        if self.activeCallbacks == 0 {
            self.condition.broadcast()
        }
        self.condition.unlock()

        if chunk.isEmpty {
            handle.readabilityHandler = nil
        } else {
            self.onData?()
        }
        continuation?.resume()
    }

    #if os(Linux)
    private func runLinuxReader(fileDescriptor: Int32) {
        var pollDescriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)

        while true {
            self.condition.lock()
            let shouldStop = self.isStopping
            self.condition.unlock()
            if shouldStop { break }

            pollDescriptor.revents = 0
            #if canImport(Glibc)
            let pollResult = Glibc.poll(&pollDescriptor, 1, 25)
            #elseif canImport(Musl)
            let pollResult = Musl.poll(&pollDescriptor, 1, 25)
            #endif
            if pollResult < 0 {
                if errno == EINTR { continue }
                self.finishLinuxRead(reachedEOF: false)
                break
            }
            if pollResult == 0 { continue }

            self.handleLinuxReadableData(fileDescriptor: fileDescriptor)
            self.condition.lock()
            let finished = self.isFinished || self.isStopping
            self.condition.unlock()
            if finished { break }
        }

        try? self.handle.close()
        self.condition.lock()
        self.readerExited = true
        self.condition.broadcast()
        self.condition.unlock()
    }

    private func handleLinuxReadableData(fileDescriptor: Int32) {
        self.condition.lock()
        guard !self.isStopping else {
            self.condition.unlock()
            return
        }
        self.activeCallbacks += 1
        self.condition.unlock()

        var receivedData = false
        var reachedEnd = false
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                #if canImport(Glibc)
                Glibc.read(fileDescriptor, bytes.baseAddress, bytes.count)
                #elseif canImport(Musl)
                Musl.read(fileDescriptor, bytes.baseAddress, bytes.count)
                #endif
            }
            if bytesRead > 0 {
                receivedData = true
                self.condition.lock()
                let remainingBytes = max(0, self.maxBytes - self.data.count)
                if remainingBytes > 0 {
                    self.data.append(contentsOf: buffer.prefix(min(remainingBytes, Int(bytesRead))))
                }
                let shouldStop = self.isStopping
                self.condition.broadcast()
                self.condition.unlock()
                if shouldStop {
                    break
                }
                continue
            }
            if bytesRead == 0 {
                reachedEnd = true
                break
            }
            if errno == EINTR {
                continue
            }
            if errno != EAGAIN, errno != EWOULDBLOCK {
                reachedEnd = true
            }
            break
        }

        var continuation: CheckedContinuation<Void, Never>?
        self.condition.lock()
        if reachedEnd {
            self.isFinished = true
            self.didReachEOF = true
            continuation = self.continuation
            self.continuation = nil
        }
        self.activeCallbacks -= 1
        if self.activeCallbacks == 0 || reachedEnd {
            self.condition.broadcast()
        }
        self.condition.unlock()

        if receivedData {
            self.scheduleLinuxDataCallback()
        }
        continuation?.resume()
    }

    private func finishLinuxRead(reachedEOF: Bool) {
        let continuation: CheckedContinuation<Void, Never>?
        self.condition.lock()
        if self.isStopping {
            continuation = nil
        } else {
            self.isFinished = true
            self.didReachEOF = reachedEOF
            continuation = self.continuation
            self.continuation = nil
            self.condition.broadcast()
        }
        self.condition.unlock()
        continuation?.resume()
    }

    private func scheduleLinuxDataCallback() {
        guard self.onData != nil else { return }
        self.condition.lock()
        self.callbackRequested = true
        guard !self.callbackScheduled else {
            self.condition.unlock()
            return
        }
        self.callbackScheduled = true
        self.condition.unlock()

        self.callbackQueue.async {
            self.deliverLinuxDataCallbacks()
        }
    }

    private func deliverLinuxDataCallbacks() {
        while true {
            self.condition.lock()
            guard self.callbackRequested else {
                self.callbackScheduled = false
                self.condition.unlock()
                return
            }
            self.callbackRequested = false
            self.condition.unlock()
            self.onData?()
        }
    }

    private func finishFailedLinuxStart() {
        try? self.handle.close()
        self.condition.lock()
        self.isFinished = true
        self.readerExited = true
        let continuation = self.continuation
        self.continuation = nil
        self.condition.broadcast()
        self.condition.unlock()
        continuation?.resume()
    }
    #endif

    private func installReadabilityHandler() {
        self.handle.readabilityHandler = { [weak self] handle in
            self?.handleReadableData(from: handle)
        }
    }

    private func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            self.condition.lock()
            if self.isFinished || self.isStopping {
                self.condition.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            self.condition.unlock()
        }
    }

    private func stopAndSnapshot() -> Data {
        let continuation: CheckedContinuation<Void, Never>?
        let snapshot: Data
        #if os(Linux)
        self.condition.lock()
        self.isStopping = true
        let closeUnstartedReader = !self.readerStarted
        if closeUnstartedReader {
            self.readerExited = true
        }
        self.condition.broadcast()
        self.condition.unlock()
        if closeUnstartedReader {
            try? self.handle.close()
        }
        #else
        self.handle.readabilityHandler = nil
        #endif

        self.condition.lock()
        self.isStopping = true
        #if os(Linux)
        while self.activeCallbacks > 0 || (self.readerStarted && !self.readerExited) {
            self.condition.wait()
        }
        #else
        while self.activeCallbacks > 0 {
            self.condition.wait()
        }
        #endif
        self.isFinished = true
        continuation = self.continuation
        self.continuation = nil
        snapshot = self.data
        self.condition.unlock()

        // Linux closes from the reader's single exit path (or the never-started path above). On Darwin,
        // clearing readabilityHandler does not release its duplicated monitor descriptor immediately.
        #if !os(Linux)
        try? self.handle.close()
        #endif

        continuation?.resume()
        return snapshot
    }

    #if os(Linux)
    private static func makeNonBlocking(fileDescriptor: Int32) -> Bool {
        guard fileDescriptor >= 0 else { return false }
        #if canImport(Glibc)
        let flags = Glibc.fcntl(fileDescriptor, F_GETFL)
        #elseif canImport(Musl)
        let flags = Musl.fcntl(fileDescriptor, F_GETFL)
        #endif
        guard flags >= 0 else { return false }
        #if canImport(Glibc)
        return Glibc.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
        #elseif canImport(Musl)
        return Musl.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
        #endif
    }
    #endif
}
