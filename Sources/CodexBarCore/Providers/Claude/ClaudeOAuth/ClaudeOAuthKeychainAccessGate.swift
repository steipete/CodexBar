import Foundation

#if os(macOS)
import os.lock

public enum ClaudeOAuthKeychainAccessGate {
    private struct State {
        var loaded = false
        var deniedUntil: Date?
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let defaultsKey = "claudeOAuthKeychainDeniedUntil"
    private static let cooldownInterval: TimeInterval = 60 * 60 * 6

    public static func shouldAllowPrompt(now: Date = Date()) -> Bool {
        guard !KeychainAccessGate.isDisabled else { return false }
        return self.lock.withLock { state in
            self.loadIfNeeded(&state)
            if let deniedUntil = state.deniedUntil {
                if deniedUntil > now {
                    return false
                }
                state.deniedUntil = nil
                self.persist(state)
            }
            return true
        }
    }

    public static func recordDenied(now: Date = Date()) {
        let deniedUntil = now.addingTimeInterval(self.cooldownInterval)
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            state.deniedUntil = deniedUntil
            self.persist(state)
        }
    }

    #if DEBUG
    public static func resetForTesting() {
        self.lock.withLock { state in
            // Keep deterministic during tests: avoid re-loading UserDefaults written by unrelated code paths.
            state.loaded = true
            state.deniedUntil = nil
            UserDefaults.standard.removeObject(forKey: self.defaultsKey)
        }
    }

    public static func resetInMemoryForTesting() {
        self.lock.withLock { state in
            state.loaded = false
            state.deniedUntil = nil
        }
    }
    #endif

    private static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        if let raw = UserDefaults.standard.object(forKey: self.defaultsKey) as? Double {
            state.deniedUntil = Date(timeIntervalSince1970: raw)
        }
    }

    private static func persist(_ state: State) {
        if let deniedUntil = state.deniedUntil {
            UserDefaults.standard.set(deniedUntil.timeIntervalSince1970, forKey: self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.defaultsKey)
        }
    }
}
#else
public enum ClaudeOAuthKeychainAccessGate {
    public static func shouldAllowPrompt(now _: Date = Date()) -> Bool {
        true
    }

    public static func recordDenied(now _: Date = Date()) {}

    #if DEBUG
    public static func resetForTesting() {}

    public static func resetInMemoryForTesting() {}
    #endif
}
#endif
