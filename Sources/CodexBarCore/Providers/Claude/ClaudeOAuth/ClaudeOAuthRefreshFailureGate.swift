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
        var blockedUntil: Date?
        var fingerprintAtFailure: AuthFingerprint?
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let blockedUntilKey = "claudeOAuthRefreshBackoffBlockedUntilV1"
    private static let failureCountKey = "claudeOAuthRefreshBackoffFailureCountV1"
    private static let fingerprintKey = "claudeOAuthRefreshBackoffFingerprintV2"

    private static let baseInterval: TimeInterval = 60 * 5
    private static let maxInterval: TimeInterval = 60 * 60 * 6
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
            state.blockedUntil = nil
            state.fingerprintAtFailure = nil
            UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
            UserDefaults.standard.removeObject(forKey: self.failureCountKey)
            UserDefaults.standard.removeObject(forKey: self.fingerprintKey)
        }
    }
    #endif

    public static func shouldAttempt(now: Date = Date()) -> Bool {
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            guard let blockedUntil = state.blockedUntil else { return true }

            if blockedUntil <= now {
                state.blockedUntil = nil
                self.persist(state)
                return true
            }

            if self.hasCredentialsChangedSinceFailure(state) {
                self.resetState(&state)
                self.persist(state)
                return true
            }

            self.log.debug(
                "Claude OAuth refresh backoff active",
                metadata: [
                    "until": "\(blockedUntil.timeIntervalSince1970)",
                    "failures": "\(state.failureCount)",
                ])
            return false
        }
    }

    public static func recordAuthFailure(now: Date = Date()) {
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            state.failureCount += 1
            state.blockedUntil = now.addingTimeInterval(self.cooldownInterval(failures: state.failureCount))
            state.fingerprintAtFailure = self.currentFingerprint()
            self.persist(state)
        }
    }

    public static func recordSuccess() {
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            self.resetState(&state)
            self.persist(state)
        }
    }

    private static func cooldownInterval(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let factor = pow(2.0, Double(failures - 1))
        return min(self.baseInterval * factor, self.maxInterval)
    }

    private static func hasCredentialsChangedSinceFailure(_ state: State) -> Bool {
        guard let prior = state.fingerprintAtFailure else { return false }
        guard let current = self.currentFingerprint() else { return false }
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

    private static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true

        state.failureCount = UserDefaults.standard.integer(forKey: self.failureCountKey)
        if let raw = UserDefaults.standard.object(forKey: self.blockedUntilKey) as? Double {
            state.blockedUntil = Date(timeIntervalSince1970: raw)
        }
        if let data = UserDefaults.standard.data(forKey: self.fingerprintKey),
           let decoded = try? JSONDecoder().decode(
               AuthFingerprint.self,
               from: data)
        {
            state.fingerprintAtFailure = decoded
        }
    }

    private static func persist(_ state: State) {
        UserDefaults.standard.set(state.failureCount, forKey: self.failureCountKey)
        if let blockedUntil = state.blockedUntil {
            UserDefaults.standard.set(blockedUntil.timeIntervalSince1970, forKey: self.blockedUntilKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
        }

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
        state.blockedUntil = nil
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
