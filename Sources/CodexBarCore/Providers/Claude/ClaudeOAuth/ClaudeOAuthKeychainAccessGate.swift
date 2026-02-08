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
    @TaskLocal private static var taskOverrideShouldAllowPromptForTesting: Bool?
    #if DEBUG
    final class DeniedUntilStore: @unchecked Sendable {
        var deniedUntil: Date?
    }

    @TaskLocal private static var taskDeniedUntilStoreOverrideForTesting: DeniedUntilStore?
    #endif

    public static func shouldAllowPrompt(now: Date = Date()) -> Bool {
        guard !KeychainAccessGate.isDisabled else { return false }
        if let override = self.taskOverrideShouldAllowPromptForTesting { return override }
        #if DEBUG
        if let store = self.taskDeniedUntilStoreOverrideForTesting {
            if let deniedUntil = store.deniedUntil, deniedUntil > now {
                return false
            }
            store.deniedUntil = nil
            return true
        }
        #endif
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
        #if DEBUG
        if let store = self.taskDeniedUntilStoreOverrideForTesting {
            store.deniedUntil = deniedUntil
            return
        }
        #endif
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            state.deniedUntil = deniedUntil
            self.persist(state)
        }
    }

    /// Clears the cooldown so the next attempt can proceed. Intended for user-initiated repairs.
    /// - Returns: true if a cooldown was present and cleared.
    public static func clearDenied(now: Date = Date()) -> Bool {
        #if DEBUG
        if let store = self.taskDeniedUntilStoreOverrideForTesting {
            guard let deniedUntil = store.deniedUntil, deniedUntil > now else {
                store.deniedUntil = nil
                return false
            }
            store.deniedUntil = nil
            return true
        }
        #endif
        return self.lock.withLock { state in
            self.loadIfNeeded(&state)
            guard let deniedUntil = state.deniedUntil, deniedUntil > now else {
                state.deniedUntil = nil
                self.persist(state)
                return false
            }
            state.deniedUntil = nil
            self.persist(state)
            return true
        }
    }

    #if DEBUG
    static func withShouldAllowPromptOverrideForTesting<T>(
        _ value: Bool?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskOverrideShouldAllowPromptForTesting.withValue(value) {
            try operation()
        }
    }

    static func withShouldAllowPromptOverrideForTesting<T>(
        _ value: Bool?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskOverrideShouldAllowPromptForTesting.withValue(value) {
            try await operation()
        }
    }

    static func withDeniedUntilStoreOverrideForTesting<T>(
        _ store: DeniedUntilStore?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskDeniedUntilStoreOverrideForTesting.withValue(store) {
            try operation()
        }
    }

    static func withDeniedUntilStoreOverrideForTesting<T>(
        _ store: DeniedUntilStore?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskDeniedUntilStoreOverrideForTesting.withValue(store) {
            try await operation()
        }
    }

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

    public static func clearDenied(now _: Date = Date()) -> Bool {
        false
    }

    #if DEBUG
    public static func resetForTesting() {}

    public static func resetInMemoryForTesting() {}
    #endif
}
#endif
