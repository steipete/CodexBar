#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

protocol ClaudeOAuthPendingCacheClearStore: Sendable {
    var isPending: Bool { get }

    func markPending()
    func withCacheTransaction(_ operation: (inout Bool) -> Void)
}

final class ClaudeOAuthPendingCacheClearUserDefaultsStore: ClaudeOAuthPendingCacheClearStore, @unchecked Sendable {
    private static let processLock = NSLock()
    private static let log = CodexBarLog.logger(LogCategories.claudeUsage)

    private let domain: String
    private let key: String
    private let lockURL: URL

    init(
        domain: String,
        key: String,
        lockURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codexbar", isDirectory: true)
            .appendingPathComponent("claude-oauth-cache.lock"))
    {
        self.domain = domain
        self.key = key
        self.lockURL = lockURL
    }

    var isPending: Bool {
        do {
            return try self.withInterprocessLock {
                self.currentGeneration() != nil
            }
        } catch {
            Self.log.error("Claude OAuth cache tombstone lock failed: \(error.localizedDescription)")
            return true
        }
    }

    func markPending() {
        do {
            try self.withInterprocessLock {
                self.writeGeneration(UUID().uuidString)
            }
        } catch {
            // A surviving tombstone is safer than allowing a stale cache read. If the lock itself is unavailable,
            // write a fresh generation but never clear one through the unlocked fallback path.
            Self.log.error("Claude OAuth cache tombstone lock failed: \(error.localizedDescription)")
            self.writeGeneration(UUID().uuidString)
        }
    }

    func withCacheTransaction(_ operation: (inout Bool) -> Void) {
        do {
            try self.withInterprocessLock {
                let initialGeneration = self.currentGeneration()
                var pending = initialGeneration != nil
                operation(&pending)
                self.persist(
                    pending: pending,
                    initialGeneration: initialGeneration)
            }
        } catch {
            Self.log.error("Claude OAuth cache transaction lock failed: \(error.localizedDescription)")
            // Fail closed: without the shared lock, do not touch the cache and leave a fresh invalidation marker.
            self.writeGeneration(UUID().uuidString)
        }
    }

    private func persist(
        pending: Bool,
        initialGeneration: String?)
    {
        let currentGeneration = self.currentGeneration()
        if pending {
            if currentGeneration == nil {
                self.writeGeneration(UUID().uuidString)
            }
            return
        }

        // Compare the observed generation before removal. This is defensive against writers that do not yet honor
        // the lock, while the lock serializes all current app and bundled-CLI cache mutations.
        guard currentGeneration == initialGeneration else { return }
        self.writeGeneration(nil)
    }

    private func currentGeneration() -> String? {
        let userDefaults = UserDefaults(suiteName: self.domain) ?? .standard
        userDefaults.synchronize()
        if let generation = userDefaults.string(forKey: self.key), !generation.isEmpty {
            return generation
        }
        // V1 stored a boolean. Preserve an outstanding invalidation across the generation-based upgrade.
        if userDefaults.object(forKey: self.key) as? Bool == true {
            return "legacy-boolean"
        }
        return nil
    }

    private func writeGeneration(_ generation: String?) {
        let userDefaults = UserDefaults(suiteName: self.domain) ?? .standard
        if let generation {
            userDefaults.set(generation, forKey: self.key)
        } else {
            userDefaults.removeObject(forKey: self.key)
        }
        userDefaults.synchronize()
    }

    private func withInterprocessLock<T>(_ operation: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        try FileManager.default.createDirectory(
            at: self.lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let fd = open(self.lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }

        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return try operation()
    }
}
