import Foundation
#if os(Linux)
import Glibc
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
    private let readerQueue = DispatchQueue(label: "com.steipete.CodexBar.process-pipe-capture.reader")
    private let callbackQueue = DispatchQueue(label: "com.steipete.CodexBar.process-pipe-capture.callback")
    private var readSource: DispatchSourceRead?
    private var sourceStarted = false
    private var sourceCancelled = false
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
        let fileDescriptor = self.handle.fileDescriptor
        guard linuxDescriptorSetup(fileDescriptor) else {
            self.finishFailedLinuxStart()
            return
        }

        // FileHandle.readabilityHandler duplicates the descriptor on Linux and traps if dup(2) returns EMFILE.
        // A dispatch read source monitors the pipe's existing descriptor, so descriptor exhaustion cannot trigger
        // Foundation's precondition failure.
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: self.readerQueue)
        source.setEventHandler { [weak self] in
            self?.handleLinuxReadableData(fileDescriptor: fileDescriptor)
        }
        source.setCancelHandler { [weak self] in
            self?.finishLinuxSourceCancellation()
        }
        self.condition.lock()
        self.readSource = source
        self.sourceStarted = true
        self.condition.unlock()
        source.resume()
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
                Glibc.read(fileDescriptor, bytes.baseAddress, bytes.count)
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
        var sourceToCancel: DispatchSourceRead?
        self.condition.lock()
        if reachedEnd {
            self.isFinished = true
            self.didReachEOF = true
            continuation = self.continuation
            self.continuation = nil
            sourceToCancel = self.readSource
        }
        self.activeCallbacks -= 1
        if self.activeCallbacks == 0 || reachedEnd {
            self.condition.broadcast()
        }
        self.condition.unlock()

        sourceToCancel?.cancel()
        if receivedData {
            self.scheduleLinuxDataCallback()
        }
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
        let continuation = self.continuation
        self.continuation = nil
        self.condition.broadcast()
        self.condition.unlock()
        continuation?.resume()
    }

    private func finishLinuxSourceCancellation() {
        try? self.handle.close()
        self.condition.lock()
        self.sourceCancelled = true
        self.readSource = nil
        self.condition.broadcast()
        self.condition.unlock()
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
        let source: DispatchSourceRead?
        self.condition.lock()
        self.isStopping = true
        source = self.readSource
        self.readSource = nil
        self.condition.unlock()
        source?.cancel()
        #else
        self.handle.readabilityHandler = nil
        #endif

        self.condition.lock()
        self.isStopping = true
        #if os(Linux)
        while self.activeCallbacks > 0 || (self.sourceStarted && !self.sourceCancelled) {
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

        // Explicitly close the read-end file descriptor. On Linux
        // swift-corelibs-foundation, clearing readabilityHandler does not
        // release the underlying dup'd monitor fd, so the pipe read end leaks
        // if we rely solely on closeOnDealloc. Closing here prevents the
        // long-running fd growth that leads to EMFILE/SIGILL (issue #2234).
        #if !os(Linux)
        try? self.handle.close()
        #endif

        continuation?.resume()
        return snapshot
    }

    #if os(Linux)
    private static func makeNonBlocking(fileDescriptor: Int32) -> Bool {
        guard fileDescriptor >= 0 else { return false }
        let flags = Glibc.fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else { return false }
        return Glibc.fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }
    #endif
}
