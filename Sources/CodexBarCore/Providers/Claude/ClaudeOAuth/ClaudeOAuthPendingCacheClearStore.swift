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
    func isPending(profileIdentifier: String) -> Bool
    func markPending(profileIdentifier: String)
    /// False means the generation was not committed; discard any tentative result.
    @discardableResult
    func withCacheTransaction(
        profileIdentifier: String,
        includingGeneration operation: (inout Bool, inout Bool, inout Bool, inout String?) -> Void) -> Bool
}

extension ClaudeOAuthPendingCacheClearStore {
    @discardableResult
    func withCacheTransaction(profileIdentifier: String, _ operation: (inout Bool) -> Void) -> Bool {
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

    @discardableResult
    func withCacheTransaction(
        profileIdentifier: String,
        includingLegacyCleanup operation: (inout Bool, inout Bool) -> Void) -> Bool
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

    @discardableResult
    func withCacheTransaction(
        profileIdentifier: String,
        includingLegacyState operation: (inout Bool, inout Bool, inout Bool) -> Void) -> Bool
    {
        self.withCacheTransaction(
            profileIdentifier: profileIdentifier,
            includingGeneration: { pending, cleanup, recheck, _ in
                operation(&pending, &cleanup, &recheck)
            })
    }
}

final class ClaudeOAuthPendingCacheClearUserDefaultsStore: ClaudeOAuthPendingCacheClearStore, @unchecked Sendable {
    private static let processLock = NSLock()
    private static let log = CodexBarLog.logger(LogCategories.provider(.claude, scope: "usage"))
    private static let legacyProfileIdentifier = "__legacy__"
    private static let legacyCleanupProfilePrefix = "__legacy_cleanup__."
    private static let legacyRecheckProfilePrefix = "__legacy_recheck__."
    private static let unlockedProfileFallbackKeyPrefix = ".unlocked-profile."

    private let domain: String
    private let key: String
    let lockURL: URL
    private let userDefaults: UserDefaults

    init(
        domain: String,
        key: String,
        lockURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexBar/claude-oauth-cache.lock"))
    {
        self.domain = domain
        self.key = key
        self.lockURL = lockURL
        self.userDefaults = ClaudeOAuthApplicationDefaults.resolve(domain: domain)
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

    @discardableResult
    func withCacheTransaction(
        profileIdentifier: String,
        includingGeneration operation: (inout Bool, inout Bool, inout Bool, inout String?) -> Void) -> Bool
    {
        do {
            return try self.withInterprocessLock {
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
                    var generation = hadUnscopedPending || initialFallbackGeneration != nil
                        ? nil : generations[profileIdentifier]
                    operation(&profilePending, &legacyCleanupPending, &legacyRecheckPending, &generation)
                    generations[Self.legacyProfileIdentifier] = nil
                    if profilePending {
                        generations[profileIdentifier] = generation ?? UUID().uuidString
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
                    guard self.unlockedProfileFallbackGeneration(profileIdentifier: profileIdentifier)
                        == initialFallbackGeneration else { return false }
                    let persisted = self.persist(
                        generations: generations,
                        initialGenerations: initialGenerations)
                    if persisted {
                        self.consumeUnlockedProfileFallbackGeneration(
                            initialFallbackGeneration,
                            profileIdentifier: profileIdentifier)
                    }
                    return persisted && self
                        .unlockedProfileFallbackGeneration(profileIdentifier: profileIdentifier) == nil
                case let .legacy(initialGeneration):
                    // V1 did not distinguish profile invalidation from legacy-key cleanup. The first
                    // profile-owned transaction claims both responsibilities and persists any retry
                    // independently in the profile-aware layout.
                    var profilePending = true
                    var legacyCleanupPending = true
                    var legacyRecheckPending = false
                    var generation: String?
                    operation(&profilePending, &legacyCleanupPending, &legacyRecheckPending, &generation)
                    guard self.currentGeneration() == initialGeneration else { return false }
                    self.writeProfileGenerations(self.pendingGenerations(
                        profileIdentifier: profileIdentifier,
                        profilePending: profilePending,
                        legacyCleanupPending: legacyCleanupPending,
                        legacyRecheckPending: legacyRecheckPending,
                        profileGeneration: generation))
                    self.consumeUnlockedProfileFallbackGeneration(
                        initialFallbackGeneration,
                        profileIdentifier: profileIdentifier)
                    return self.unlockedProfileFallbackGeneration(profileIdentifier: profileIdentifier) == nil
                case .none:
                    var profilePending = initialFallbackGeneration != nil
                    var legacyCleanupPending = false
                    var legacyRecheckPending = false
                    var generation: String?
                    operation(&profilePending, &legacyCleanupPending, &legacyRecheckPending, &generation)
                    guard case .none = self.currentState() else { return false }
                    self.writeProfileGenerations(self.pendingGenerations(
                        profileIdentifier: profileIdentifier,
                        profilePending: profilePending,
                        legacyCleanupPending: legacyCleanupPending,
                        legacyRecheckPending: legacyRecheckPending,
                        profileGeneration: generation))
                    self.consumeUnlockedProfileFallbackGeneration(
                        initialFallbackGeneration,
                        profileIdentifier: profileIdentifier)
                    return self.unlockedProfileFallbackGeneration(profileIdentifier: profileIdentifier) == nil
                }
            }
        } catch {
            Self.log.error("Claude OAuth cache transaction lock failed: \(error.localizedDescription)")
            // Fail closed: without the shared lock, do not touch the cache and leave a fresh invalidation marker.
            self.writeUnlockedProfileFallbackGeneration(
                UUID().uuidString,
                profileIdentifier: profileIdentifier)
            return false
        }
    }

    private func currentGeneration() -> String? {
        let userDefaults = self.userDefaults
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
        let userDefaults = self.userDefaults
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
        legacyRecheckPending: Bool,
        profileGeneration: String?) -> [String: String]
    {
        var generations: [String: String] = [:]
        if profilePending {
            generations[profileIdentifier] = profileGeneration ?? UUID().uuidString
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
        let userDefaults = self.userDefaults
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
        let userDefaults = self.userDefaults
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
        let userDefaults = self.userDefaults
        let fallbackKey = self.unlockedProfileFallbackKey(profileIdentifier: profileIdentifier)
        if let generation {
            userDefaults.set(generation, forKey: fallbackKey)
        } else {
            userDefaults.removeObject(forKey: fallbackKey)
        }
        userDefaults.synchronize()
    }

    private func writeProfileGenerations(_ generations: [String: String]) {
        let userDefaults = self.userDefaults
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
