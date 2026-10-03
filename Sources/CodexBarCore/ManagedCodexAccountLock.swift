import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum ManagedCodexAccountLockError: Error, LocalizedError, Equatable {
    case busy
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .busy: "Another CodexBar process is changing managed accounts. Try again after it finishes."
        case .unavailable: "Could not lock the managed Codex account store."
        }
    }
}

/// Participating writers share this lock; reads and provider requests never mutate the live authentication.
package enum ManagedCodexAccountLock {
    @TaskLocal private static var heldPaths: Set<String> = []

    package static func withLock<T>(at url: URL?, operation: () throws -> T) throws -> T {
        guard let url, !self.heldPaths.contains(url.standardizedFileURL.path) else { return try operation() }
        let descriptor = try self.acquire(url)
        defer { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
        return try self.$heldPaths.withValue(self.heldPaths.union([url.standardizedFileURL.path]), operation: operation)
    }

    @MainActor
    package static func withLock<T>(at url: URL?, operation: () async throws -> T) async throws -> T {
        guard let url, !self.heldPaths.contains(url.standardizedFileURL.path) else { return try await operation() }
        let descriptor = try self.acquire(url)
        defer { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
        return try await self.$heldPaths.withValue(
            self.heldPaths.union([url.standardizedFileURL.path]), operation: operation)
    }

    private static func acquire(_ url: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = url.path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else { throw ManagedCodexAccountLockError.unavailable }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == getuid(), status.st_nlink == 1, fchmod(descriptor, mode_t(0o600)) == 0
        else { _ = close(descriptor); throw ManagedCodexAccountLockError.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            _ = close(descriptor)
            throw busy ? ManagedCodexAccountLockError.busy : ManagedCodexAccountLockError.unavailable
        }
        return descriptor
    }
}
