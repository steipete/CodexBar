import Foundation

#if os(macOS)
import os.lock

public enum ClaudeOAuthRefreshFailureGate {
    public enum BlockStatus: Equatable, Sendable {
        case terminal(reason: String?, failures: Int)
        case transient(until: Date, failures: Int)
    }

    struct AuthFingerprint: Codable, Equatable, Sendable {
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

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
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

    #if DEBUG
    @TaskLocal static var shouldAttemptOverride: Bool?
    private nonisolated(unsafe) static var fingerprintProviderOverride: (() -> AuthFingerprint?)?

    static func setFingerprintProviderOverrideForTesting(_ provider: (() -> AuthFingerprint?)?) {
        self.fingerprintProviderOverride = provider
    }

    public static func resetInMemoryStateForTesting() {
        self.lock.withLock { state in
            state.loaded = false
            state.terminalFailureCount = 0
            state.transientFailureCount = 0
            state.isTerminalBlocked = false
            state.transientBlockedUntil = nil
            state.fingerprintAtFailure = nil
            state.lastCredentialsRecheckAt = nil
            state.terminalReason = nil
        }
    }

    public static func resetForTesting() {
        self.lock.withLock { state in
            state.loaded = false
            state.terminalFailureCount = 0
            state.transientFailureCount = 0
            state.isTerminalBlocked = false
            state.transientBlockedUntil = nil
            state.fingerprintAtFailure = nil
            state.lastCredentialsRecheckAt = nil
            state.terminalReason = nil
            UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
            UserDefaults.standard.removeObject(forKey: self.failureCountKey)
            UserDefaults.standard.removeObject(forKey: self.fingerprintKey)
            UserDefaults.standard.removeObject(forKey: self.terminalBlockedKey)
            UserDefaults.standard.removeObject(forKey: self.terminalReasonKey)
            UserDefaults.standard.removeObject(forKey: self.transientBlockedUntilKey)
            UserDefaults.standard.removeObject(forKey: self.transientFailureCountKey)
        }
    }
    #endif

    public static func shouldAttempt(now: Date = Date()) -> Bool {
        #if DEBUG
        if let override = self.shouldAttemptOverride { return override }
        #endif

        return self.lock.withLock { state in
            let didMigrate = self.loadIfNeeded(&state, now: now)
            if didMigrate {
                self.persist(state)
            }

            if state.isTerminalBlocked {
                guard self.shouldRecheckCredentials(now: now, state: state) else { return false }

                state.lastCredentialsRecheckAt = now
                if self.hasCredentialsChangedSinceFailure(state) {
                    self.resetState(&state)
                    self.persist(state)
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
                    self.persist(state)
                    return true
                }

                if self.shouldRecheckCredentials(now: now, state: state) {
                    state.lastCredentialsRecheckAt = now
                    if self.hasCredentialsChangedSinceFailure(state) {
                        self.resetState(&state)
                        self.persist(state)
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

    public static func currentBlockStatus(now: Date = Date()) -> BlockStatus? {
        self.lock.withLock { state in
            _ = self.loadIfNeeded(&state, now: now)
            if state.isTerminalBlocked {
                return .terminal(reason: state.terminalReason, failures: state.terminalFailureCount)
            }
            if let blockedUntil = state.transientBlockedUntil, blockedUntil > now {
                return .transient(until: blockedUntil, failures: state.transientFailureCount)
            }
            return nil
        }
    }

    public static func recordTerminalAuthFailure(now: Date = Date()) {
        self.lock.withLock { state in
            _ = self.loadIfNeeded(&state, now: now)
            state.terminalFailureCount += 1
            state.isTerminalBlocked = true
            state.terminalReason = "invalid_grant"
            state.fingerprintAtFailure = self.currentFingerprint() ?? self.unknownFingerprint
            state.lastCredentialsRecheckAt = now
            self.clearTransientState(&state)
            self.persist(state)
        }
    }

    public static func recordTransientFailure(now: Date = Date()) {
        self.lock.withLock { state in
            _ = self.loadIfNeeded(&state, now: now)

            // Keep terminal blocking monotonic: once we know auth is rejected (e.g. invalid_grant),
            // do not downgrade it to time-based backoff unless auth changes (fingerprint) or we record success.
            guard !state.isTerminalBlocked else { return }

            self.clearTerminalState(&state)

            state.transientFailureCount += 1
            let interval = self.transientCooldownInterval(failures: state.transientFailureCount)
            state.transientBlockedUntil = now.addingTimeInterval(interval)
            state.fingerprintAtFailure = self.currentFingerprint() ?? self.unknownFingerprint
            state.lastCredentialsRecheckAt = now
            self.persist(state)
        }
    }

    public static func recordAuthFailure(now: Date = Date()) {
        // Legacy shim: treat as terminal auth failure.
        self.recordTerminalAuthFailure(now: now)
    }

    public static func recordSuccess() {
        self.lock.withLock { state in
            _ = self.loadIfNeeded(&state, now: Date())
            self.resetState(&state)
            self.persist(state)
        }
    }

    private static func shouldRecheckCredentials(now: Date, state: State) -> Bool {
        guard let last = state.lastCredentialsRecheckAt else { return true }
        return now.timeIntervalSince(last) >= self.minimumCredentialsRecheckInterval
    }

    private static func hasCredentialsChangedSinceFailure(_ state: State) -> Bool {
        guard let current = self.currentFingerprint() else { return false }
        guard let prior = state.fingerprintAtFailure else { return false }
        return current != prior
    }

    private static func currentFingerprint() -> AuthFingerprint? {
        #if DEBUG
        if let override = self.fingerprintProviderOverride { return override() }
        #endif
        return AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.currentClaudeKeychainFingerprintWithoutPromptForAuthGate(),
            credentialsFile: ClaudeOAuthCredentialsStore.currentCredentialsFileFingerprintWithoutPromptForAuthGate())
    }

    private static func loadIfNeeded(_ state: inout State, now: Date) -> Bool {
        state.loaded = true
        var didMutate = false

        // Always refresh persisted fields from UserDefaults, even after first load.
        //
        // This avoids stale state when UserDefaults are modified while the app is running (or during tests),
        // while still keeping ephemeral throttling state (like lastCredentialsRecheckAt) in memory.
        state.terminalFailureCount = UserDefaults.standard.integer(forKey: self.failureCountKey)
        state.transientFailureCount = UserDefaults.standard.integer(forKey: self.transientFailureCountKey)

        if let raw = UserDefaults.standard.object(forKey: self.transientBlockedUntilKey) as? Double {
            state.transientBlockedUntil = Date(timeIntervalSince1970: raw)
        }

        let legacyBlockedUntil = (UserDefaults.standard.object(forKey: self.blockedUntilKey) as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        let legacyFailureCount = UserDefaults.standard.integer(forKey: self.failureCountKey)

        if let data = UserDefaults.standard.data(forKey: self.fingerprintKey) {
            state.fingerprintAtFailure = (try? JSONDecoder().decode(AuthFingerprint.self, from: data))
        } else {
            state.fingerprintAtFailure = nil
        }

        if UserDefaults.standard.object(forKey: self.terminalBlockedKey) != nil {
            state.isTerminalBlocked = UserDefaults.standard.bool(forKey: self.terminalBlockedKey)
            state.terminalReason = UserDefaults.standard.string(forKey: self.terminalReasonKey)
            if legacyBlockedUntil != nil {
                didMutate = true
            }
        } else {
            // Migration: legacy keys represented a time-based backoff. Migrate to transient backoff (never terminal)
            // unless we already have new transient keys persisted.
            if UserDefaults.standard.object(forKey: self.transientFailureCountKey) == nil,
               UserDefaults.standard.object(forKey: self.transientBlockedUntilKey) == nil,
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

        return didMutate
    }

    private static func persist(_ state: State) {
        UserDefaults.standard.set(state.terminalFailureCount, forKey: self.failureCountKey)
        UserDefaults.standard.set(state.isTerminalBlocked, forKey: self.terminalBlockedKey)
        if let reason = state.terminalReason {
            UserDefaults.standard.set(reason, forKey: self.terminalReasonKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.terminalReasonKey)
        }

        UserDefaults.standard.set(state.transientFailureCount, forKey: self.transientFailureCountKey)
        if let blockedUntil = state.transientBlockedUntil {
            UserDefaults.standard.set(blockedUntil.timeIntervalSince1970, forKey: self.transientBlockedUntilKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.transientBlockedUntilKey)
        }

        UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)

        if let fingerprint = state.fingerprintAtFailure,
           let data = try? JSONEncoder().encode(fingerprint)
        {
            UserDefaults.standard.set(data, forKey: self.fingerprintKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.fingerprintKey)
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

    public static func shouldAttempt(now _: Date = Date()) -> Bool {
        true
    }

    public static func currentBlockStatus(now _: Date = Date()) -> BlockStatus? {
        nil
    }

    public static func recordTerminalAuthFailure(now _: Date = Date()) {}

    public static func recordTransientFailure(now _: Date = Date()) {}

    public static func recordAuthFailure(now _: Date = Date()) {}

    public static func recordSuccess() {}

    #if DEBUG
    static func setFingerprintProviderOverrideForTesting(_: (() -> Any?)?) {}
    public static func resetInMemoryStateForTesting() {}
    public static func resetForTesting() {}
    #endif
}
#endif
