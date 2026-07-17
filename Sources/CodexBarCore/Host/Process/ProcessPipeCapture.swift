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
    private var usesReadableHandler = true

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
        // swift-corelibs-foundation's readabilityHandler setter duplicates the
        // underlying fd to create a dispatch source. If the process is already at
        // EMFILE, that dup fails and the setter traps with precondition(_fd >= 0),
        // producing the SIGILL reported in issue #2234. Defensively probe whether
        // we can duplicate the fd ourselves; if not, fall back to synchronous
        // reading in stopAndSnapshot() instead of installing the handler.
        let fd = self.handle.fileDescriptor
        let probe = Glibc.dup(fd)
        guard probe != -1 else {
            self.usesReadableHandler = false
            return
        }
        Glibc.close(probe)
        #endif

        self.handle.readabilityHandler = { [weak self] handle in
            self?.handleReadableData(from: handle)
        }
    }

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

    private func drainSynchronously() {
        while !self.isStopping {
            let chunk = self.handle.availableData
            self.condition.lock()
            if chunk.isEmpty {
                self.isFinished = true
                self.didReachEOF = true
                self.condition.broadcast()
                self.condition.unlock()
                return
            }
            let remainingBytes = max(0, self.maxBytes - self.data.count)
            if remainingBytes > 0 {
                self.data.append(chunk.prefix(remainingBytes))
            }
            self.onData?()
            self.condition.broadcast()
            self.condition.unlock()
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
        self.handle.readabilityHandler = nil

        // If we could not install the readability handler (e.g. EMFILE on Linux),
        // read whatever data is available synchronously before closing the fd.
        if !self.usesReadableHandler {
            self.drainSynchronously()
        }

        let continuation: CheckedContinuation<Void, Never>?
        let snapshot: Data
        self.condition.lock()
        self.isStopping = true
        while self.activeCallbacks > 0 {
            self.condition.wait()
        }
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
        try? self.handle.close()

        continuation?.resume()
        return snapshot
    }
}
