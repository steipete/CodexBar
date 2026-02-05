import Foundation

#if os(macOS)
import os.lock

public enum ClaudeOAuthRefreshFailureGate {
    struct AuthFingerprint: Codable, Equatable, Sendable {
        let keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?
        let credentialsFile: String?
    }

    private struct State {
        var loaded = false
        var failureCount = 0
        var isTerminalBlocked = false
        var fingerprintAtFailure: AuthFingerprint?
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let blockedUntilKey = "claudeOAuthRefreshBackoffBlockedUntilV1" // legacy (migration)
    private static let failureCountKey = "claudeOAuthRefreshBackoffFailureCountV1"
    private static let fingerprintKey = "claudeOAuthRefreshBackoffFingerprintV2"
    private static let terminalBlockedKey = "claudeOAuthRefreshTerminalBlockedV1"

    private static let log = CodexBarLog.logger(LogCategories.claudeUsage)

    #if DEBUG
    private nonisolated(unsafe) static var fingerprintProviderOverride: (() -> AuthFingerprint?)?

    static func setFingerprintProviderOverrideForTesting(_ provider: (() -> AuthFingerprint?)?) {
        self.fingerprintProviderOverride = provider
    }

    public static func resetForTesting() {
        self.lock.withLock { state in
            state.loaded = false
            state.failureCount = 0
            state.isTerminalBlocked = false
            state.fingerprintAtFailure = nil
            UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
            UserDefaults.standard.removeObject(forKey: self.failureCountKey)
            UserDefaults.standard.removeObject(forKey: self.fingerprintKey)
            UserDefaults.standard.removeObject(forKey: self.terminalBlockedKey)
        }
    }
    #endif

    public static func shouldAttempt(now: Date = Date()) -> Bool {
        _ = now
        return self.lock.withLock { state in
            let didMigrate = self.loadIfNeeded(&state)
            if didMigrate {
                self.persist(state)
            }

            guard state.isTerminalBlocked else { return true }

            if self.hasCredentialsChangedSinceFailure(state) {
                self.resetState(&state)
                self.persist(state)
                return true
            }

            self.log.debug(
                "Claude OAuth refresh blocked until auth changes",
                metadata: [
                    "failures": "\(state.failureCount)",
                ])
            return false
        }
    }

    public static func recordAuthFailure(now: Date = Date()) {
        _ = now
        self.lock.withLock { state in
            _ = self.loadIfNeeded(&state)
            state.failureCount += 1
            state.isTerminalBlocked = true
            state.fingerprintAtFailure = self.currentFingerprint()
            self.persist(state)
        }
    }

    public static func recordSuccess() {
        self.lock.withLock { state in
            _ = self.loadIfNeeded(&state)
            self.resetState(&state)
            self.persist(state)
        }
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

    private static func loadIfNeeded(_ state: inout State) -> Bool {
        guard !state.loaded else { return false }
        state.loaded = true
        var didMutate = false

        state.failureCount = UserDefaults.standard.integer(forKey: self.failureCountKey)
        let hasLegacyBlockedUntil = UserDefaults.standard.object(forKey: self.blockedUntilKey) != nil
        if let data = UserDefaults.standard.data(forKey: self.fingerprintKey),
           let decoded = try? JSONDecoder().decode(
               AuthFingerprint.self,
               from: data)
        {
            state.fingerprintAtFailure = decoded
        }

        if UserDefaults.standard.object(forKey: self.terminalBlockedKey) == nil {
            // Migration: previously the gate used an exponential backoff time window and only recorded failures for
            // refresh auth failures (HTTP 400/401). Treat any persisted legacy state as terminal-blocked.
            if state.failureCount > 0 || hasLegacyBlockedUntil {
                state.isTerminalBlocked = true
                didMutate = true
            }
        } else {
            state.isTerminalBlocked = UserDefaults.standard.bool(forKey: self.terminalBlockedKey)
        }

        // Normalize: clear legacy blocked-until state once terminal mode is in effect.
        if state.isTerminalBlocked, hasLegacyBlockedUntil {
            didMutate = true
        }

        // If we're blocked but have no stored fingerprint (e.g. migration, decode failure), pin the current
        // fingerprint so we only unblock on an actual auth change.
        if state.isTerminalBlocked, state.fingerprintAtFailure == nil {
            state.fingerprintAtFailure = self.currentFingerprint()
            didMutate = true
        }

        return didMutate
    }

    private static func persist(_ state: State) {
        UserDefaults.standard.set(state.failureCount, forKey: self.failureCountKey)
        UserDefaults.standard.set(state.isTerminalBlocked, forKey: self.terminalBlockedKey)
        UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)

        if let fingerprint = state.fingerprintAtFailure,
           let data = try? JSONEncoder().encode(fingerprint)
        {
            UserDefaults.standard.set(data, forKey: self.fingerprintKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.fingerprintKey)
        }
    }

    private static func resetState(_ state: inout State) {
        state.failureCount = 0
        state.isTerminalBlocked = false
        state.fingerprintAtFailure = nil
    }
}
#else
public enum ClaudeOAuthRefreshFailureGate {
    public static func shouldAttempt(now _: Date = Date()) -> Bool {
        true
    }

    public static func recordAuthFailure(now _: Date = Date()) {}

    public static func recordSuccess() {}

    #if DEBUG
    static func setFingerprintProviderOverrideForTesting(_: (() -> Any?)?) {}
    public static func resetForTesting() {}
    #endif
}
#endif
