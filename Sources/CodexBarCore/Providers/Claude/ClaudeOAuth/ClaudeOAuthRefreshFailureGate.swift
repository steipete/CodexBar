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
        var terminalFailureCount = 0
        var transientFailureCount = 0
        var isTerminalBlocked = false
        var transientBlockedUntil: Date?
        var fingerprintAtFailure: AuthFingerprint?
        var lastCredentialsRecheckAt: Date?
        var terminalReason: String?
    }

    private static let lock = OSAllocatedUnfairLock<[String: State]>(initialState: [:])
    private static let blockedUntilKey = "claudeOAuthRefreshBackoffBlockedUntilV1" // legacy (migration)
    private static let failureCountKey = "claudeOAuthRefreshBackoffFailureCountV1" // legacy + terminal count
    private static let fingerprintKey = "claudeOAuthRefreshBackoffFingerprintV2"
    private static let terminalBlockedKey = "claudeOAuthRefreshTerminalBlockedV1"
    private static let terminalReasonKey = "claudeOAuthRefreshTerminalReasonV1"
    private static let transientBlockedUntilKey = "claudeOAuthRefreshTransientBlockedUntilV1"
    private static let transientFailureCountKey = "claudeOAuthRefreshTransientFailureCountV1"

    private static let log = CodexBarLog.logger(LogCategories.claudeUsage)
    private static let minimumCredentialsRecheckInterval: TimeInterval = 15
    private static let unknownFingerprint = AuthFingerprint(keychain: nil, credentialsFile: nil)
    private static let transientBaseInterval: TimeInterval = 60 * 5
    private static let transientMaxInterval: TimeInterval = 60 * 60 * 6
    private static let profileKeySeparator = ".profile."

    #if DEBUG
    @TaskLocal static var shouldAttemptOverride: Bool?

    final class FingerprintProviderOverrideStore: @unchecked Sendable {
        let provider: () -> AuthFingerprint?

        init(provider: @escaping () -> AuthFingerprint?) {
            self.provider = provider
        }
    }

    @TaskLocal private static var taskFingerprintProviderOverrideStore: FingerprintProviderOverrideStore?

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
        self.lock.withLock { states in
            states.removeAll()
        }
    }

    public static func resetForTesting() {
        self.lock.withLock { states in
            states.removeAll()
            let defaults = UserDefaults.standard
            for key in defaults.dictionaryRepresentation().keys where self.isFailureGatePersistenceKey(key) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    static func profileIdentifierForTesting(environment: [String: String]) -> String {
        self.profileIdentifier(environment: environment)
    }

    static func scopedPersistenceKeyForTesting(
        _ baseKey: String,
        environment: [String: String]) -> String
    {
        self.scopedKey(baseKey, profileIdentifier: self.profileIdentifier(environment: environment))
    }
    #endif

    public static func shouldAttempt(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) -> Bool
    {
        self.shouldAttempt(
            profileIdentifier: self.profileIdentifier(environment: environment),
            environment: environment,
            now: now)
    }

    static func shouldAttempt(
        profileIdentifier: String,
        environment: [String: String],
        now: Date = Date()) -> Bool
    {
        #if DEBUG
        if let override = self.shouldAttemptOverride { return override }
        #endif

        return self.lock.withLock { states in
            var state = states[profileIdentifier] ?? State()
            defer { states[profileIdentifier] = state }
            let didMigrate = self.loadIfNeeded(
                &state,
                profileIdentifier: profileIdentifier,
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
                        "profile": String(profileIdentifier.prefix(12)),
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
                        "profile": String(profileIdentifier.prefix(12)),
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
        self.currentBlockStatus(
            profileIdentifier: self.profileIdentifier(environment: environment),
            environment: environment,
            now: now)
    }

    static func currentBlockStatus(
        profileIdentifier: String,
        environment _: [String: String],
        now: Date = Date()) -> BlockStatus?
    {
        self.lock.withLock { states in
            var state = states[profileIdentifier] ?? State()
            defer { states[profileIdentifier] = state }
            let didMigrate = self.loadIfNeeded(
                &state,
                profileIdentifier: profileIdentifier,
                now: now)
            if didMigrate {
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
        self.recordTerminalAuthFailure(
            profileIdentifier: self.profileIdentifier(environment: environment),
            environment: environment,
            now: now)
    }

    static func recordTerminalAuthFailure(
        profileIdentifier: String,
        environment: [String: String],
        now: Date = Date())
    {
        self.lock.withLock { states in
            var state = states[profileIdentifier] ?? State()
            defer { states[profileIdentifier] = state }
            _ = self.loadIfNeeded(&state, profileIdentifier: profileIdentifier, now: now)
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
        self.recordTransientFailure(
            profileIdentifier: self.profileIdentifier(environment: environment),
            environment: environment,
            now: now)
    }

    static func recordTransientFailure(
        profileIdentifier: String,
        environment: [String: String],
        now: Date = Date())
    {
        self.lock.withLock { states in
            var state = states[profileIdentifier] ?? State()
            defer { states[profileIdentifier] = state }
            _ = self.loadIfNeeded(&state, profileIdentifier: profileIdentifier, now: now)

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

    static func recordAuthFailure(
        profileIdentifier: String,
        environment: [String: String],
        now: Date = Date())
    {
        self.recordTerminalAuthFailure(
            profileIdentifier: profileIdentifier,
            environment: environment,
            now: now)
    }

    public static func recordSuccess(
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.recordSuccess(
            profileIdentifier: self.profileIdentifier(environment: environment),
            environment: environment)
    }

    static func recordSuccess(
        profileIdentifier: String,
        environment _: [String: String])
    {
        self.lock.withLock { states in
            var state = states[profileIdentifier] ?? State()
            defer { states[profileIdentifier] = state }
            _ = self.loadIfNeeded(&state, profileIdentifier: profileIdentifier, now: Date())
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
        if let override = self.taskFingerprintProviderOverrideStore { return override.provider() }
        #endif
        return AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.currentClaudeKeychainFingerprintWithoutPromptForAuthGate(),
            credentialsFile: ClaudeOAuthCredentialsStore.currentCredentialsFileFingerprintWithoutPromptForAuthGate(
                environment: environment))
    }

    private static func loadIfNeeded(
        _ state: inout State,
        profileIdentifier: String,
        now: Date) -> Bool
    {
        var didMutate = false
        let defaults = UserDefaults.standard
        let failureCountKey = self.scopedKey(self.failureCountKey, profileIdentifier: profileIdentifier)
        let fingerprintKey = self.scopedKey(self.fingerprintKey, profileIdentifier: profileIdentifier)
        let terminalBlockedKey = self.scopedKey(self.terminalBlockedKey, profileIdentifier: profileIdentifier)
        let terminalReasonKey = self.scopedKey(self.terminalReasonKey, profileIdentifier: profileIdentifier)
        let transientBlockedUntilKey = self.scopedKey(
            self.transientBlockedUntilKey,
            profileIdentifier: profileIdentifier)
        let transientFailureCountKey = self.scopedKey(
            self.transientFailureCountKey,
            profileIdentifier: profileIdentifier)
        let hasScopedState = [
            failureCountKey,
            fingerprintKey,
            terminalBlockedKey,
            terminalReasonKey,
            transientBlockedUntilKey,
            transientFailureCountKey,
        ].contains { defaults.object(forKey: $0) != nil }

        // Always refresh persisted fields from UserDefaults, even after first load.
        //
        // This avoids stale state when UserDefaults are modified while the app is running (or during tests),
        // while still keeping ephemeral throttling state (like lastCredentialsRecheckAt) in memory.
        state.terminalFailureCount = defaults.integer(forKey: failureCountKey)
        state.transientFailureCount = defaults.integer(forKey: transientFailureCountKey)

        state.transientBlockedUntil = (defaults.object(forKey: transientBlockedUntilKey) as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        state.isTerminalBlocked = defaults.bool(forKey: terminalBlockedKey)
        state.terminalReason = defaults.string(forKey: terminalReasonKey)
        state.fingerprintAtFailure = defaults.data(forKey: fingerprintKey)
            .flatMap { try? JSONDecoder().decode(AuthFingerprint.self, from: $0) }

        let isDefaultProfile = profileIdentifier == self.profileIdentifier(
            environment: ProcessInfo.processInfo.environment)
        let hasUnscopedState = self.unscopedPersistenceKeys.contains {
            defaults.object(forKey: $0) != nil
        }
        guard isDefaultProfile, hasUnscopedState else {
            if state.isTerminalBlocked || state.transientBlockedUntil != nil, state.fingerprintAtFailure == nil {
                state.fingerprintAtFailure = self.unknownFingerprint
                didMutate = true
            }
            return didMutate
        }

        guard !hasScopedState else {
            self.clearUnscopedPersistence(defaults: defaults)
            if state.isTerminalBlocked || state.transientBlockedUntil != nil, state.fingerprintAtFailure == nil {
                state.fingerprintAtFailure = self.unknownFingerprint
                return true
            }
            return false
        }

        let legacyBlockedUntil = (defaults.object(forKey: self.blockedUntilKey) as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        let legacyFailureCount = defaults.integer(forKey: self.failureCountKey)

        if let data = defaults.data(forKey: self.fingerprintKey) {
            state.fingerprintAtFailure = (try? JSONDecoder().decode(AuthFingerprint.self, from: data))
        } else {
            state.fingerprintAtFailure = nil
        }

        if defaults.object(forKey: self.terminalBlockedKey) != nil {
            state.isTerminalBlocked = defaults.bool(forKey: self.terminalBlockedKey)
            state.terminalFailureCount = legacyFailureCount
            state.terminalReason = defaults.string(forKey: self.terminalReasonKey)
            state.transientFailureCount = defaults.integer(forKey: self.transientFailureCountKey)
            state.transientBlockedUntil = (defaults.object(forKey: self.transientBlockedUntilKey) as? Double)
                .map { Date(timeIntervalSince1970: $0) }
            didMutate = true
        } else {
            // Migration: legacy keys represented a time-based backoff. Migrate to transient backoff (never terminal)
            // unless we already have new transient keys persisted.
            if defaults.object(forKey: self.transientFailureCountKey) == nil,
               defaults.object(forKey: self.transientBlockedUntilKey) == nil,
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
            } else if defaults.object(forKey: self.transientFailureCountKey) != nil ||
                defaults.object(forKey: self.transientBlockedUntilKey) != nil
            {
                state.transientFailureCount = defaults.integer(forKey: self.transientFailureCountKey)
                state.transientBlockedUntil = (defaults.object(forKey: self.transientBlockedUntilKey) as? Double)
                    .map { Date(timeIntervalSince1970: $0) }
                didMutate = true
            }
        }

        if state.isTerminalBlocked || state.transientBlockedUntil != nil, state.fingerprintAtFailure == nil {
            state.fingerprintAtFailure = self.unknownFingerprint
            didMutate = true
        }

        self.clearUnscopedPersistence(defaults: defaults)
        return didMutate
    }

    private static func persist(_ state: State, profileIdentifier: String) {
        let defaults = UserDefaults.standard
        let failureCountKey = self.scopedKey(self.failureCountKey, profileIdentifier: profileIdentifier)
        let terminalBlockedKey = self.scopedKey(self.terminalBlockedKey, profileIdentifier: profileIdentifier)
        let terminalReasonKey = self.scopedKey(self.terminalReasonKey, profileIdentifier: profileIdentifier)
        let transientFailureCountKey = self.scopedKey(
            self.transientFailureCountKey,
            profileIdentifier: profileIdentifier)
        let transientBlockedUntilKey = self.scopedKey(
            self.transientBlockedUntilKey,
            profileIdentifier: profileIdentifier)
        let fingerprintKey = self.scopedKey(self.fingerprintKey, profileIdentifier: profileIdentifier)

        defaults.set(state.terminalFailureCount, forKey: failureCountKey)
        defaults.set(state.isTerminalBlocked, forKey: terminalBlockedKey)
        if let reason = state.terminalReason {
            defaults.set(reason, forKey: terminalReasonKey)
        } else {
            defaults.removeObject(forKey: terminalReasonKey)
        }

        defaults.set(state.transientFailureCount, forKey: transientFailureCountKey)
        if let blockedUntil = state.transientBlockedUntil {
            defaults.set(blockedUntil.timeIntervalSince1970, forKey: transientBlockedUntilKey)
        } else {
            defaults.removeObject(forKey: transientBlockedUntilKey)
        }

        if let fingerprint = state.fingerprintAtFailure,
           let data = try? JSONEncoder().encode(fingerprint)
        {
            defaults.set(data, forKey: fingerprintKey)
        } else {
            defaults.removeObject(forKey: fingerprintKey)
        }
    }

    private static var unscopedPersistenceKeys: [String] {
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

    private static func clearUnscopedPersistence(defaults: UserDefaults) {
        for key in self.unscopedPersistenceKeys {
            defaults.removeObject(forKey: key)
        }
    }

    private static func isFailureGatePersistenceKey(_ key: String) -> Bool {
        self.unscopedPersistenceKeys.contains(key) ||
            self.unscopedPersistenceKeys.contains { key.hasPrefix($0 + self.profileKeySeparator) }
    }

    private static func scopedKey(_ baseKey: String, profileIdentifier: String) -> String {
        baseKey + self.profileKeySeparator + profileIdentifier
    }

    private static func profileIdentifier(environment: [String: String]) -> String {
        ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
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

    static func shouldAttempt(
        profileIdentifier _: String,
        environment _: [String: String],
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

    static func currentBlockStatus(
        profileIdentifier _: String,
        environment _: [String: String],
        now _: Date = Date()) -> BlockStatus?
    {
        nil
    }

    public static func recordTerminalAuthFailure(
        environment _: [String: String] = ProcessInfo.processInfo.environment,
        now _: Date = Date()) {}

    static func recordTerminalAuthFailure(
        profileIdentifier _: String,
        environment _: [String: String],
        now _: Date = Date()) {}

    public static func recordTransientFailure(
        environment _: [String: String] = ProcessInfo.processInfo.environment,
        now _: Date = Date()) {}

    static func recordTransientFailure(
        profileIdentifier _: String,
        environment _: [String: String],
        now _: Date = Date()) {}

    public static func recordAuthFailure(
        environment _: [String: String] = ProcessInfo.processInfo.environment,
        now _: Date = Date()) {}

    static func recordAuthFailure(
        profileIdentifier _: String,
        environment _: [String: String],
        now _: Date = Date()) {}

    public static func recordSuccess(
        environment _: [String: String] = ProcessInfo.processInfo.environment) {}

    static func recordSuccess(
        profileIdentifier _: String,
        environment _: [String: String]) {}

    #if DEBUG
    static func withFingerprintProviderOverrideForTesting<T>(
        _ override: (() -> Any?)?,
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
