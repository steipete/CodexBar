import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Serializes the Codex cost-cache publication protocol across app and CLI processes.
///
/// The lock file is deliberately independent of the JSON artifact version: future cache
/// versions can still share the token-index sidecar, so they must stay in the same lock domain.
enum CostUsageCodexRefreshLock {
    enum Acquisition {
        case acquired(Lease)
        case contended
    }

    final class Lease: @unchecked Sendable {
        private let stateLock = NSLock()
        private var fileDescriptors: [Int32]

        fileprivate init(fileDescriptors: [Int32]) {
            self.fileDescriptors = fileDescriptors
        }

        /// Releases the kernel lease. Calling this more than once is harmless.
        func release() {
            self.stateLock.lock()
            let descriptors = self.fileDescriptors
            self.fileDescriptors = []
            self.stateLock.unlock()

            for fd in descriptors.reversed() {
                _ = flock(fd, LOCK_UN)
                _ = close(fd)
            }
        }

        deinit {
            self.release()
        }
    }

    static func lockFileURL(cacheRoot: URL? = nil) -> URL {
        // Provider-specific by design: only Codex has the cross-process bounded-scan refresh lease.
        CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: cacheRoot)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("codex-refresh.lock", isDirectory: false)
    }

    /// A stable barrier shared by every cache in one explicitly selected cache family.
    ///
    /// Spend Dashboard account caches are nested below the live cache's `cost-usage` tree.
    /// Their callers pass the live cache root as `lockDomainRoot`, keeping this barrier above
    /// the directory a global clear removes. Unrelated custom cache roots remain independent.
    static func clearBarrierFileURL(
        cacheRoot: URL? = nil,
        lockDomainRoot: URL? = nil) -> URL
    {
        // Provider-specific by design: only Codex nests account caches under the shared clear-barrier domain.
        let localRoot = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: cacheRoot)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return (lockDomainRoot ?? localRoot)
            .standardizedFileURL
            .appendingPathComponent("codex-cache-clear.lock", isDirectory: false)
    }

    /// Attempts to acquire the exclusive refresh lease without waiting for another process.
    /// Callers that receive `.contended` must remain read-only for that refresh.
    static func tryAcquire(
        cacheRoot: URL? = nil,
        lockDomainRoot: URL? = nil,
        fileManager: FileManager = .default) throws -> Acquisition
    {
        let barrierURL = self.clearBarrierFileURL(
            cacheRoot: cacheRoot,
            lockDomainRoot: lockDomainRoot)
        let barrier = try self.tryAcquireFile(
            at: barrierURL,
            operation: LOCK_SH | LOCK_NB,
            fileManager: fileManager)
        guard case let .acquired(barrierDescriptor) = barrier else { return .contended }

        do {
            let local = try self.tryAcquireFile(
                at: self.lockFileURL(cacheRoot: cacheRoot),
                operation: LOCK_EX | LOCK_NB,
                fileManager: fileManager)
            switch local {
            case let .acquired(localDescriptor):
                return .acquired(Lease(fileDescriptors: [barrierDescriptor, localDescriptor]))
            case .contended:
                self.releaseFile(barrierDescriptor)
                return .contended
            }
        } catch {
            self.releaseFile(barrierDescriptor)
            throw error
        }
    }

    /// Acquires the stable barrier exclusively before a cache tree is removed. Taking the
    /// local lock as well preserves same-root exclusion and keeps one lock order everywhere.
    static func tryAcquireForClear(
        cacheRoot: URL? = nil,
        lockDomainRoot: URL? = nil,
        fileManager: FileManager = .default) throws -> Acquisition
    {
        let barrier = try self.tryAcquireFile(
            at: self.clearBarrierFileURL(
                cacheRoot: cacheRoot,
                lockDomainRoot: lockDomainRoot),
            operation: LOCK_EX | LOCK_NB,
            fileManager: fileManager)
        guard case let .acquired(barrierDescriptor) = barrier else { return .contended }

        do {
            let local = try self.tryAcquireFile(
                at: self.lockFileURL(cacheRoot: cacheRoot),
                operation: LOCK_EX | LOCK_NB,
                fileManager: fileManager)
            switch local {
            case let .acquired(localDescriptor):
                return .acquired(Lease(fileDescriptors: [barrierDescriptor, localDescriptor]))
            case .contended:
                self.releaseFile(barrierDescriptor)
                return .contended
            }
        } catch {
            self.releaseFile(barrierDescriptor)
            throw error
        }
    }

    private enum FileAcquisition {
        case acquired(Int32)
        case contended
    }

    private static func tryAcquireFile(
        at url: URL,
        operation: Int32,
        fileManager: FileManager) throws -> FileAcquisition
    {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        while true {
            if flock(fd, operation) == 0 {
                return .acquired(fd)
            }

            let errorCode = errno
            if errorCode == EINTR {
                continue
            }

            _ = close(fd)
            if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                return .contended
            }
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }
    }

    private static func releaseFile(_ fileDescriptor: Int32) {
        _ = flock(fileDescriptor, LOCK_UN)
        _ = close(fileDescriptor)
    }
}
