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

    func isPending(profileIdentifier: String) -> Bool
    func markPending(profileIdentifier: String)
    func withCacheTransaction(profileIdentifier: String, _ operation: (inout Bool) -> Void)
    func withCacheTransaction(
        profileIdentifier: String,
        includingLegacyCleanup operation: (inout Bool, inout Bool) -> Void)
    func withCacheTransaction(
        profileIdentifier: String,
        includingLegacyState operation: (inout Bool, inout Bool, inout Bool) -> Void)
}

final class ClaudeOAuthPendingCacheClearUserDefaultsStore: ClaudeOAuthPendingCacheClearStore, @unchecked Sendable {
    private static let processLock = NSLock()
    private static let log = CodexBarLog.logger(LogCategories.claudeUsage)
    private static let legacyProfileIdentifier = "__legacy__"
    private static let legacyCleanupProfilePrefix = "__legacy_cleanup__."
    private static let legacyRecheckProfilePrefix = "__legacy_recheck__."
    private static let unlockedProfileFallbackKeyPrefix = ".unlocked-profile."

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
                if case .none = self.currentState() {
                    return self.hasAnyUnlockedProfileFallback
                }
                return true
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

    func isPending(profileIdentifier: String) -> Bool {
        do {
            return try self.withInterprocessLock {
                if self.unlockedProfileFallbackGeneration(profileIdentifier: profileIdentifier) != nil {
                    return true
                }
                return switch self.currentState() {
                case let .profiles(generations):
                    generations[profileIdentifier] != nil ||
                        generations[Self.legacyProfileIdentifier] != nil ||
                        generations[Self.legacyCleanupIdentifier(profileIdentifier: profileIdentifier)] != nil ||
                        generations[Self.legacyRecheckIdentifier(profileIdentifier: profileIdentifier)] != nil
                case .legacy:
                    // A V1 tombstone did not record its source profile. Treat it as pending until
                    // the first profile-owned retry resolves it; no current code writes V1 state.
                    true
                case .none:
                    false
                }
            }
        } catch {
            Self.log.error("Claude OAuth cache tombstone lock failed: \(error.localizedDescription)")
            return true
        }
    }

    func markPending(profileIdentifier: String) {
        do {
            try self.withInterprocessLock {
                var generations = self.currentProfileGenerations()
                generations[profileIdentifier] = UUID().uuidString
                self.writeProfileGenerations(generations)
            }
        } catch {
            // Preserve the failed invalidation's owner. A shared V1 fallback could be claimed and
            // removed by another profile before this profile's stale cache was cleared.
            Self.log.error("Claude OAuth cache tombstone lock failed: \(error.localizedDescription)")
            self.writeUnlockedProfileFallbackGeneration(
                UUID().uuidString,
                profileIdentifier: profileIdentifier)
        }
    }

    func withCacheTransaction(profileIdentifier: String, _ operation: (inout Bool) -> Void) {
        self.withCacheTransaction(
            profileIdentifier: profileIdentifier,
            includingLegacyCleanup: { profilePending, legacyCleanupPending in
                var pending = profilePending || legacyCleanupPending
                operation(&pending)
                if pending {
                    if !profilePending, !legacyCleanupPending {
                        profilePending = true
                    }
                } else {
                    profilePending = false
                    legacyCleanupPending = false
                }
            })
    }

    func withCacheTransaction(
        profileIdentifier: String,
        includingLegacyCleanup operation: (inout Bool, inout Bool) -> Void)
    {
        self.withCacheTransaction(
            profileIdentifier: profileIdentifier,
            includingLegacyState: { profilePending, legacyCleanupPending, legacyRecheckPending in
                operation(&profilePending, &legacyCleanupPending)
                if legacyCleanupPending {
                    legacyRecheckPending = false
                }
            })
    }

    func withCacheTransaction(
        profileIdentifier: String,
        includingLegacyState operation: (inout Bool, inout Bool, inout Bool) -> Void)
    {
        do {
            try self.withInterprocessLock {
                let initialFallbackGeneration = self.unlockedProfileFallbackGeneration(
                    profileIdentifier: profileIdentifier)
                switch self.currentState() {
                case let .profiles(initialGenerations):
                    var generations = initialGenerations
                    let hadUnscopedPending = generations[Self.legacyProfileIdentifier] != nil
                    let legacyCleanupIdentifier = Self.legacyCleanupIdentifier(
                        profileIdentifier: profileIdentifier)
                    let legacyRecheckIdentifier = Self.legacyRecheckIdentifier(
                        profileIdentifier: profileIdentifier)
                    var profilePending = hadUnscopedPending ||
                        generations[profileIdentifier] != nil ||
                        initialFallbackGeneration != nil
                    var legacyCleanupPending = hadUnscopedPending ||
                        generations[legacyCleanupIdentifier] != nil
                    var legacyRecheckPending = generations[legacyRecheckIdentifier] != nil
                    operation(&profilePending, &legacyCleanupPending, &legacyRecheckPending)
                    generations[Self.legacyProfileIdentifier] = nil
                    if profilePending {
                        generations[profileIdentifier] = generations[profileIdentifier] ?? UUID().uuidString
                    } else {
                        generations[profileIdentifier] = nil
                    }
                    if legacyCleanupPending {
                        generations[legacyCleanupIdentifier] =
                            generations[legacyCleanupIdentifier] ?? UUID().uuidString
                    } else {
                        generations[legacyCleanupIdentifier] = nil
                    }
                    if legacyRecheckPending {
                        generations[legacyRecheckIdentifier] =
                            generations[legacyRecheckIdentifier] ?? UUID().uuidString
                    } else {
                        generations[legacyRecheckIdentifier] = nil
                    }
                    let persisted = self.persist(
                        generations: generations,
                        initialGenerations: initialGenerations)
                    if persisted {
                        self.consumeUnlockedProfileFallbackGeneration(
                            initialFallbackGeneration,
                            profileIdentifier: profileIdentifier)
                    }
                case let .legacy(initialGeneration):
                    // V1 did not distinguish profile invalidation from legacy-key cleanup. The first
                    // profile-owned transaction claims both responsibilities and persists any retry
                    // independently in the profile-aware layout.
                    var profilePending = true
                    var legacyCleanupPending = true
                    var legacyRecheckPending = false
                    operation(&profilePending, &legacyCleanupPending, &legacyRecheckPending)
                    guard self.currentGeneration() == initialGeneration else { return }
                    self.writeProfileGenerations(self.pendingGenerations(
                        profileIdentifier: profileIdentifier,
                        profilePending: profilePending,
                        legacyCleanupPending: legacyCleanupPending,
                        legacyRecheckPending: legacyRecheckPending))
                    self.consumeUnlockedProfileFallbackGeneration(
                        initialFallbackGeneration,
                        profileIdentifier: profileIdentifier)
                case .none:
                    var profilePending = initialFallbackGeneration != nil
                    var legacyCleanupPending = false
                    var legacyRecheckPending = false
                    operation(&profilePending, &legacyCleanupPending, &legacyRecheckPending)
                    self.writeProfileGenerations(self.pendingGenerations(
                        profileIdentifier: profileIdentifier,
                        profilePending: profilePending,
                        legacyCleanupPending: legacyCleanupPending,
                        legacyRecheckPending: legacyRecheckPending))
                    self.consumeUnlockedProfileFallbackGeneration(
                        initialFallbackGeneration,
                        profileIdentifier: profileIdentifier)
                }
            }
        } catch {
            Self.log.error("Claude OAuth cache transaction lock failed: \(error.localizedDescription)")
            // Fail closed: without the shared lock, do not touch the cache and leave a fresh invalidation marker.
            self.writeUnlockedProfileFallbackGeneration(
                UUID().uuidString,
                profileIdentifier: profileIdentifier)
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

    private enum State {
        case none
        case legacy(String)
        case profiles([String: String])
    }

    private func currentState() -> State {
        let userDefaults = UserDefaults(suiteName: self.domain) ?? .standard
        userDefaults.synchronize()
        if let generations = userDefaults.dictionary(forKey: self.key) as? [String: String], !generations.isEmpty {
            return .profiles(generations)
        }
        if let generation = self.currentGeneration() {
            return .legacy(generation)
        }
        return .none
    }

    private func currentProfileGenerations() -> [String: String] {
        switch self.currentState() {
        case let .profiles(generations):
            generations
        case let .legacy(generation):
            [Self.legacyProfileIdentifier: generation]
        case .none:
            [:]
        }
    }

    private static func legacyCleanupIdentifier(profileIdentifier: String) -> String {
        self.legacyCleanupProfilePrefix + profileIdentifier
    }

    private static func legacyRecheckIdentifier(profileIdentifier: String) -> String {
        self.legacyRecheckProfilePrefix + profileIdentifier
    }

    private func pendingGenerations(
        profileIdentifier: String,
        profilePending: Bool,
        legacyCleanupPending: Bool,
        legacyRecheckPending: Bool) -> [String: String]
    {
        var generations: [String: String] = [:]
        if profilePending {
            generations[profileIdentifier] = UUID().uuidString
        }
        if legacyCleanupPending {
            generations[Self.legacyCleanupIdentifier(profileIdentifier: profileIdentifier)] = UUID().uuidString
        }
        if legacyRecheckPending {
            generations[Self.legacyRecheckIdentifier(profileIdentifier: profileIdentifier)] = UUID().uuidString
        }
        return generations
    }

    private func persist(generations: [String: String], initialGenerations: [String: String]) -> Bool {
        let currentGenerations = self.currentProfileGenerations()
        guard currentGenerations == initialGenerations else { return false }
        self.writeProfileGenerations(generations)
        return true
    }

    private var hasAnyUnlockedProfileFallback: Bool {
        let userDefaults = UserDefaults(suiteName: self.domain) ?? .standard
        userDefaults.synchronize()
        let prefix = self.key + Self.unlockedProfileFallbackKeyPrefix
        return userDefaults.persistentDomain(forName: self.domain)?.keys.contains {
            $0.hasPrefix(prefix)
        } ?? false
    }

    private func unlockedProfileFallbackKey(profileIdentifier: String) -> String {
        self.key + Self.unlockedProfileFallbackKeyPrefix + profileIdentifier
    }

    private func unlockedProfileFallbackGeneration(profileIdentifier: String) -> String? {
        let userDefaults = UserDefaults(suiteName: self.domain) ?? .standard
        userDefaults.synchronize()
        let fallbackKey = self.unlockedProfileFallbackKey(profileIdentifier: profileIdentifier)
        guard let generation = userDefaults.string(forKey: fallbackKey), !generation.isEmpty else { return nil }
        return generation
    }

    private func consumeUnlockedProfileFallbackGeneration(
        _ initialGeneration: String?,
        profileIdentifier: String)
    {
        guard let initialGeneration,
              self.unlockedProfileFallbackGeneration(profileIdentifier: profileIdentifier) == initialGeneration
        else { return }
        self.writeUnlockedProfileFallbackGeneration(nil, profileIdentifier: profileIdentifier)
    }

    private func writeUnlockedProfileFallbackGeneration(
        _ generation: String?,
        profileIdentifier: String)
    {
        let userDefaults = UserDefaults(suiteName: self.domain) ?? .standard
        let fallbackKey = self.unlockedProfileFallbackKey(profileIdentifier: profileIdentifier)
        if let generation {
            userDefaults.set(generation, forKey: fallbackKey)
        } else {
            userDefaults.removeObject(forKey: fallbackKey)
        }
        userDefaults.synchronize()
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

    private func writeProfileGenerations(_ generations: [String: String]) {
        let userDefaults = UserDefaults(suiteName: self.domain) ?? .standard
        if generations.isEmpty {
            userDefaults.removeObject(forKey: self.key)
        } else {
            userDefaults.set(generations, forKey: self.key)
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
