import Foundation

#if os(macOS)
import os.lock

public enum ClaudeOAuthRefreshFailureGate {
    public enum BlockStatus: Equatable, Sendable {
        case terminal(reason: String?, failures: Int)
        case transient(until: Date, failures: Int)
    }

    struct AuthFingerprint: Codable, Equatable {
        let keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?
        let credentialsFile: String?
    }

    private struct State {
        var loaded = false
        var terminalFailureCount = 0
        var transientFailureCount = 0
        var isTerminalBlocked = false
        var transientBlockedUntil: Date?
        var fingerprintAtFailure: AuthFingerprint?
        var lastCredentialsRecheckAt: Date?
        var terminalReason: String?
    }

    private struct LockedState {
        var profiles: [String: State] = [:]
    }

    private static let lock = OSAllocatedUnfairLock<LockedState>(initialState: LockedState())
    private static let blockedUntilKey = "claudeOAuthRefreshBackoffBlockedUntilV1" // legacy (migration)
    private static let failureCountKey = "claudeOAuthRefreshBackoffFailureCountV1" // legacy + terminal count
    private static let fingerprintKey = "claudeOAuthRefreshBackoffFingerprintV2"
    private static let terminalBlockedKey = "claudeOAuthRefreshTerminalBlockedV1"
    private static let terminalReasonKey = "claudeOAuthRefreshTerminalReasonV1"
    private static let transientBlockedUntilKey = "claudeOAuthRefreshTransientBlockedUntilV1"
    private static let transientFailureCountKey = "claudeOAuthRefreshTransientFailureCountV1"
    private static let profileKeySeparator = ".profile."

    private static let log = CodexBarLog.logger(LogCategories.claudeUsage)
    private static let minimumCredentialsRecheckInterval: TimeInterval = 15
    private static let unknownFingerprint = AuthFingerprint(keychain: nil, credentialsFile: nil)
    private static let transientBaseInterval: TimeInterval = 60 * 5
    private static let transientMaxInterval: TimeInterval = 60 * 60 * 6

    #if DEBUG
    @TaskLocal static var shouldAttemptOverride: Bool?

    final class FingerprintProviderOverrideStore: @unchecked Sendable {
        let provider: () -> AuthFingerprint?

        init(provider: @escaping () -> AuthFingerprint?) {
            self.provider = provider
        }
    }

    @TaskLocal private static var taskFingerprintProviderOverrideStore: FingerprintProviderOverrideStore?

    final class EnvironmentFingerprintProviderOverrideStore: @unchecked Sendable {
        let provider: ([String: String]) -> AuthFingerprint?

        init(provider: @escaping ([String: String]) -> AuthFingerprint?) {
            self.provider = provider
        }
    }

    @TaskLocal private static var taskEnvironmentFingerprintProviderOverrideStore:
        EnvironmentFingerprintProviderOverrideStore?

    static func withFingerprintProviderOverrideForTesting<T>(
        _ override: (() -> AuthFingerprint?)?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskFingerprintProviderOverrideStore.withValue(
            override.map(FingerprintProviderOverrideStore.init(provider:)))
        {
            try operation()
        }
    }

    static func withEnvironmentFingerprintProviderOverrideForTesting<T>(
        _ override: (([String: String]) -> AuthFingerprint?)?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskEnvironmentFingerprintProviderOverrideStore.withValue(
            override.map(EnvironmentFingerprintProviderOverrideStore.init(provider:)))
        {
            try operation()
        }
    }

    static func withFingerprintProviderOverrideForTesting<T>(
        _ override: (() -> AuthFingerprint?)?,
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskFingerprintProviderOverrideStore.withValue(
            override.map(FingerprintProviderOverrideStore.init(provider:)))
        {
            try await operation()
        }
    }

    public static func resetInMemoryStateForTesting() {
        self.lock.withLock { lockedState in
            lockedState.profiles.removeAll()
        }
    }

    public static func resetForTesting() {
        self.lock.withLock { lockedState in
            lockedState.profiles.removeAll()
            let defaults = UserDefaults.standard
            for key in self.persistedKeys {
                defaults.removeObject(forKey: key)
            }
            for key in defaults.dictionaryRepresentation().keys
                where self.persistedKeys.contains(where: { key.hasPrefix($0 + self.profileKeySeparator) })
            {
                defaults.removeObject(forKey: key)
            }
        }
    }
    #endif

    public static func shouldAttempt(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) -> Bool
    {
        #if DEBUG
        if let override = self.shouldAttemptOverride {
            return override
        }
        #endif

        return self.withState(environment: environment) { state, profileIdentifier in
            let didMigrate = self.loadIfNeeded(
                &state,
                profileIdentifier: profileIdentifier,
                environment: environment,
                now: now)
            if didMigrate {
                self.persist(state, profileIdentifier: profileIdentifier)
            }

            if state.isTerminalBlocked {
                guard self.shouldRecheckCredentials(now: now, state: state) else { return false }

                state.lastCredentialsRecheckAt = now
                if self.hasCredentialsChangedSinceFailure(state, environment: environment) {
                    self.resetState(&state)
                    self.persist(state, profileIdentifier: profileIdentifier)
                    return true
                }

                self.log.debug(
                    "Claude OAuth refresh blocked until auth changes",
                    metadata: [
                        "terminalFailures": "\(state.terminalFailureCount)",
                        "reason": state.terminalReason ?? "nil",
                    ])
                return false
            }

            if let blockedUntil = state.transientBlockedUntil {
                if blockedUntil <= now {
                    self.clearTransientState(&state)
                    // Once transient backoff expires, forget its auth baseline so future failures capture fresh
                    // fingerprints and so we don't ratchet backoff across unrelated intermittent failures.
                    state.fingerprintAtFailure = nil
                    state.lastCredentialsRecheckAt = nil
                    self.persist(state, profileIdentifier: profileIdentifier)
                    return true
                }

                if self.shouldRecheckCredentials(now: now, state: state) {
                    state.lastCredentialsRecheckAt = now
                    if self.hasCredentialsChangedSinceFailure(state, environment: environment) {
                        self.resetState(&state)
                        self.persist(state, profileIdentifier: profileIdentifier)
                        return true
                    }
                }

                self.log.debug(
                    "Claude OAuth refresh transient backoff active",
                    metadata: [
                        "until": "\(blockedUntil.timeIntervalSince1970)",
                        "transientFailures": "\(state.transientFailureCount)",
                    ])
                return false
            }

            return true
        }
    }

    public static func currentBlockStatus(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) -> BlockStatus?
    {
        self.withState(environment: environment) { state, profileIdentifier in
            if self.loadIfNeeded(
                &state,
                profileIdentifier: profileIdentifier,
                environment: environment,
                now: now)
            {
                self.persist(state, profileIdentifier: profileIdentifier)
            }
            if state.isTerminalBlocked {
                return .terminal(reason: state.terminalReason, failures: state.terminalFailureCount)
            }
            if let blockedUntil = state.transientBlockedUntil, blockedUntil > now {
                return .transient(until: blockedUntil, failures: state.transientFailureCount)
            }
            return nil
        }
    }

    public static func recordTerminalAuthFailure(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date())
    {
        self.withState(environment: environment) { state, profileIdentifier in
            _ = self.loadIfNeeded(
                &state,
                profileIdentifier: profileIdentifier,
                environment: environment,
                now: now)
            state.terminalFailureCount += 1
            state.isTerminalBlocked = true
            state.terminalReason = "invalid_grant"
            state.fingerprintAtFailure = self.currentFingerprint(environment: environment) ?? self.unknownFingerprint
            state.lastCredentialsRecheckAt = now
            self.clearTransientState(&state)
            self.persist(state, profileIdentifier: profileIdentifier)
        }
    }

    public static func recordTransientFailure(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date())
    {
        self.withState(environment: environment) { state, profileIdentifier in
            _ = self.loadIfNeeded(
                &state,
                profileIdentifier: profileIdentifier,
                environment: environment,
                now: now)

            // Keep terminal blocking monotonic: once we know auth is rejected (e.g. invalid_grant),
            // do not downgrade it to time-based backoff unless auth changes (fingerprint) or we record success.
            guard !state.isTerminalBlocked else { return }

            self.clearTerminalState(&state)

            state.transientFailureCount += 1
            let interval = self.transientCooldownInterval(failures: state.transientFailureCount)
            state.transientBlockedUntil = now.addingTimeInterval(interval)
            state.fingerprintAtFailure = self.currentFingerprint(environment: environment) ?? self.unknownFingerprint
            state.lastCredentialsRecheckAt = now
            self.persist(state, profileIdentifier: profileIdentifier)
        }
    }

    public static func recordAuthFailure(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date())
    {
        // Legacy shim: treat as terminal auth failure.
        self.recordTerminalAuthFailure(environment: environment, now: now)
    }

    public static func recordSuccess(
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.withState(environment: environment) { state, profileIdentifier in
            _ = self.loadIfNeeded(
                &state,
                profileIdentifier: profileIdentifier,
                environment: environment,
                now: Date())
            self.resetState(&state)
            self.persist(state, profileIdentifier: profileIdentifier)
        }
    }

    private static func shouldRecheckCredentials(now: Date, state: State) -> Bool {
        guard let last = state.lastCredentialsRecheckAt else { return true }
        return now.timeIntervalSince(last) >= self.minimumCredentialsRecheckInterval
    }

    private static func hasCredentialsChangedSinceFailure(
        _ state: State,
        environment: [String: String]) -> Bool
    {
        guard let current = self.currentFingerprint(environment: environment) else { return false }
        guard let prior = state.fingerprintAtFailure else { return false }
        return current != prior
    }

    private static func currentFingerprint(environment: [String: String]) -> AuthFingerprint? {
        #if DEBUG
        if let override = self.taskEnvironmentFingerprintProviderOverrideStore {
            return override.provider(environment)
        }
        if let override = self.taskFingerprintProviderOverrideStore {
            return override.provider()
        }
        #endif
        return AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.currentClaudeKeychainFingerprintWithoutPromptForAuthGate(),
            credentialsFile: ClaudeOAuthCredentialsStore.currentCredentialsFileFingerprintWithoutPromptForAuthGate(
                environment: environment))
    }

    private static var persistedKeys: [String] {
        [
            self.blockedUntilKey,
            self.failureCountKey,
            self.fingerprintKey,
            self.terminalBlockedKey,
            self.terminalReasonKey,
            self.transientBlockedUntilKey,
            self.transientFailureCountKey,
        ]
    }

    private static func withState<T: Sendable>(
        environment: [String: String],
        operation: @Sendable (inout State, String) -> T) -> T
    {
        let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
        return self.lock.withLock { lockedState in
            var state = lockedState.profiles[profileIdentifier] ?? State()
            let result = operation(&state, profileIdentifier)
            lockedState.profiles[profileIdentifier] = state
            return result
        }
    }

    private static func profileKey(_ base: String, profileIdentifier: String) -> String {
        base + self.profileKeySeparator + profileIdentifier
    }

    private static func loadIfNeeded(
        _ state: inout State,
        profileIdentifier: String,
        environment _: [String: String],
        now: Date) -> Bool
    {
        state.loaded = true
        var didMutate = false
        let defaults = UserDefaults.standard
        let defaultProfileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
            environment: ProcessInfo.processInfo.environment)
        let scopedKey: (String) -> String = { self.profileKey($0, profileIdentifier: profileIdentifier) }
        let hasScopedState = self.persistedKeys.contains { defaults.object(forKey: scopedKey($0)) != nil }
        let hasLegacyState = self.persistedKeys.contains { defaults.object(forKey: $0) != nil }
        let shouldMigrateLegacy = !hasScopedState && profileIdentifier == defaultProfileIdentifier && hasLegacyState
        let storageKey: (String) -> String = shouldMigrateLegacy ? { $0 } : scopedKey

        // Always refresh persisted fields from UserDefaults, even after first load.
        //
        // This avoids stale state when UserDefaults are modified while the app is running (or during tests),
        // while still keeping ephemeral throttling state (like lastCredentialsRecheckAt) in memory.
        state.terminalFailureCount = defaults.integer(forKey: storageKey(self.failureCountKey))
        state.transientFailureCount = defaults.integer(forKey: storageKey(self.transientFailureCountKey))
        state.isTerminalBlocked = false
        state.terminalReason = nil
        state.transientBlockedUntil = nil
        state.fingerprintAtFailure = nil

        if let raw = defaults.object(forKey: storageKey(self.transientBlockedUntilKey)) as? Double {
            state.transientBlockedUntil = Date(timeIntervalSince1970: raw)
        }

        let legacyBlockedUntil = shouldMigrateLegacy
            ? (defaults.object(forKey: self.blockedUntilKey) as? Double).map { Date(timeIntervalSince1970: $0) }
            : nil
        let legacyFailureCount = shouldMigrateLegacy ? defaults.integer(forKey: self.failureCountKey) : 0

        if let data = defaults.data(forKey: storageKey(self.fingerprintKey)) {
            state.fingerprintAtFailure = (try? JSONDecoder().decode(AuthFingerprint.self, from: data))
        }

        if defaults.object(forKey: storageKey(self.terminalBlockedKey)) != nil {
            state.isTerminalBlocked = defaults.bool(forKey: storageKey(self.terminalBlockedKey))
            state.terminalReason = defaults.string(forKey: storageKey(self.terminalReasonKey))
            if legacyBlockedUntil != nil {
                didMutate = true
            }
        } else {
            // Migration: legacy keys represented a time-based backoff. Migrate to transient backoff (never terminal)
            // unless we already have new transient keys persisted.
            if defaults.object(forKey: storageKey(self.transientFailureCountKey)) == nil,
               defaults.object(forKey: storageKey(self.transientBlockedUntilKey)) == nil,
               legacyBlockedUntil != nil || legacyFailureCount > 0
            {
                state.isTerminalBlocked = false
                state.terminalReason = nil
                state.terminalFailureCount = 0

                if let legacyBlockedUntil, legacyBlockedUntil > now {
                    state.transientFailureCount = max(legacyFailureCount, 0)
                    state.transientBlockedUntil = legacyBlockedUntil
                } else {
                    state.transientFailureCount = 0
                    state.transientBlockedUntil = nil
                }
                didMutate = true
            }
        }

        if state.isTerminalBlocked || state.transientBlockedUntil != nil, state.fingerprintAtFailure == nil {
            state.fingerprintAtFailure = self.unknownFingerprint
            didMutate = true
        }

        if legacyBlockedUntil != nil {
            didMutate = true
        }

        if shouldMigrateLegacy {
            didMutate = true
        }

        return didMutate
    }

    private static func persist(_ state: State, profileIdentifier: String) {
        let defaults = UserDefaults.standard
        let key: (String) -> String = { self.profileKey($0, profileIdentifier: profileIdentifier) }
        defaults.set(state.terminalFailureCount, forKey: key(self.failureCountKey))
        defaults.set(state.isTerminalBlocked, forKey: key(self.terminalBlockedKey))
        if let reason = state.terminalReason {
            defaults.set(reason, forKey: key(self.terminalReasonKey))
        } else {
            defaults.removeObject(forKey: key(self.terminalReasonKey))
        }

        defaults.set(state.transientFailureCount, forKey: key(self.transientFailureCountKey))
        if let blockedUntil = state.transientBlockedUntil {
            defaults.set(blockedUntil.timeIntervalSince1970, forKey: key(self.transientBlockedUntilKey))
        } else {
            defaults.removeObject(forKey: key(self.transientBlockedUntilKey))
        }

        defaults.removeObject(forKey: key(self.blockedUntilKey))

        if let fingerprint = state.fingerprintAtFailure,
           let data = try? JSONEncoder().encode(fingerprint)
        {
            defaults.set(data, forKey: key(self.fingerprintKey))
        } else {
            defaults.removeObject(forKey: key(self.fingerprintKey))
        }

        let defaultProfileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
            environment: ProcessInfo.processInfo.environment)
        if profileIdentifier == defaultProfileIdentifier {
            for legacyKey in self.persistedKeys {
                defaults.removeObject(forKey: legacyKey)
            }
        }
    }

    private static func transientCooldownInterval(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let factor = pow(2.0, Double(failures - 1))
        return min(self.transientBaseInterval * factor, self.transientMaxInterval)
    }

    private static func clearTerminalState(_ state: inout State) {
        state.terminalFailureCount = 0
        state.isTerminalBlocked = false
        state.terminalReason = nil
    }

    private static func clearTransientState(_ state: inout State) {
        state.transientFailureCount = 0
        state.transientBlockedUntil = nil
    }

    private static func resetState(_ state: inout State) {
        self.clearTerminalState(&state)
        self.clearTransientState(&state)
        state.fingerprintAtFailure = nil
        state.lastCredentialsRecheckAt = nil
    }
}
#else
public enum ClaudeOAuthRefreshFailureGate {
    public enum BlockStatus: Equatable, Sendable {
        case terminal(reason: String?, failures: Int)
        case transient(until: Date, failures: Int)
    }

    public static func shouldAttempt(
        environment _: [String: String] = ProcessInfo.processInfo.environment,
        now _: Date = Date()) -> Bool
    {
        true
    }

    public static func currentBlockStatus(
        environment _: [String: String] = ProcessInfo.processInfo.environment,
        now _: Date = Date()) -> BlockStatus?
    {
        nil
    }

    public static func recordTerminalAuthFailure(
        environment _: [String: String] = ProcessInfo.processInfo.environment,
        now _: Date = Date()) {}

    public static func recordTransientFailure(
        environment _: [String: String] = ProcessInfo.processInfo.environment,
        now _: Date = Date()) {}

    public static func recordAuthFailure(
        environment _: [String: String] = ProcessInfo.processInfo.environment,
        now _: Date = Date()) {}

    public static func recordSuccess(
        environment _: [String: String] = ProcessInfo.processInfo.environment) {}

    #if DEBUG
    static func withFingerprintProviderOverrideForTesting<T>(
        _ override: (() -> Any?)?,
        operation: () throws -> T) rethrows -> T
    {
        try operation()
    }

    static func withEnvironmentFingerprintProviderOverrideForTesting<T>(
        _ override: (([String: String]) -> Any?)?,
        operation: () throws -> T) rethrows -> T
    {
        try operation()
    }

    static func withFingerprintProviderOverrideForTesting<T>(
        _ override: (() -> Any?)?,
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await operation()
    }

    public static func resetInMemoryStateForTesting() {}
    public static func resetForTesting() {}
    #endif
}
#endif
