import Foundation

#if os(macOS)
import os.lock

enum ClaudeOAuthKeychainPreAlertGate {
    private struct State {
        var loaded = false
        var acknowledgedUntil: Date?
        var presentationInFlight = false
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let defaultsKey = "claudeOAuthKeychainPreAlertAcknowledgedUntilV1"
    static let cooldownInterval: TimeInterval = 60 * 60 * 6

    #if DEBUG
    final class StateStore: @unchecked Sendable {
        var acknowledgedUntil: Date?
        var presentationInFlight = false
    }

    @TaskLocal private static var taskStateStoreOverrideForTesting: StateStore?
    #endif

    /// Reserves presentation so concurrent credential reads cannot show duplicate explanatory alerts.
    static func beginPresentation(now: Date = Date()) -> Bool {
        #if DEBUG
        if let store = self.taskStateStoreOverrideForTesting {
            guard !store.presentationInFlight else { return false }
            if let acknowledgedUntil = store.acknowledgedUntil, acknowledgedUntil > now {
                return false
            }
            store.acknowledgedUntil = nil
            store.presentationInFlight = true
            return true
        }
        #endif
        return self.lock.withLock { state in
            self.loadIfNeeded(&state)
            guard !state.presentationInFlight else { return false }
            if let acknowledgedUntil = state.acknowledgedUntil, acknowledgedUntil > now {
                return false
            }
            state.acknowledgedUntil = nil
            state.presentationInFlight = true
            self.persist(state)
            return true
        }
    }

    /// Completes a reservation. Only a prompt that reached an installed handler starts the cooldown.
    static func finishPresentation(wasPresented: Bool, now: Date = Date()) {
        #if DEBUG
        if let store = self.taskStateStoreOverrideForTesting {
            store.presentationInFlight = false
            if wasPresented {
                store.acknowledgedUntil = now.addingTimeInterval(self.cooldownInterval)
            }
            return
        }
        #endif
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            state.presentationInFlight = false
            if wasPresented {
                state.acknowledgedUntil = now.addingTimeInterval(self.cooldownInterval)
            }
            self.persist(state)
        }
    }

    #if DEBUG
    static func withStateStoreOverrideForTesting<T>(
        _ store: StateStore?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskStateStoreOverrideForTesting.withValue(store) {
            try operation()
        }
    }

    static func withStateStoreOverrideForTesting<T>(
        _ store: StateStore?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskStateStoreOverrideForTesting.withValue(store) {
            try await operation()
        }
    }

    static func resetForTesting() {
        self.lock.withLock { state in
            state = State(loaded: true)
            UserDefaults.standard.removeObject(forKey: self.defaultsKey)
        }
    }

    static func resetInMemoryForTesting() {
        self.lock.withLock { state in
            state = State()
        }
    }
    #endif

    private static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        if let raw = UserDefaults.standard.object(forKey: self.defaultsKey) as? Double {
            state.acknowledgedUntil = Date(timeIntervalSince1970: raw)
        }
    }

    private static func persist(_ state: State) {
        if let acknowledgedUntil = state.acknowledgedUntil {
            UserDefaults.standard.set(acknowledgedUntil.timeIntervalSince1970, forKey: self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.defaultsKey)
        }
    }
}
#else
enum ClaudeOAuthKeychainPreAlertGate {
    static let cooldownInterval: TimeInterval = 60 * 60 * 6

    #if DEBUG
    final class StateStore: @unchecked Sendable {}
    #endif

    static func beginPresentation(now _: Date = Date()) -> Bool {
        false
    }

    static func finishPresentation(wasPresented _: Bool, now _: Date = Date()) {}

    #if DEBUG
    static func withStateStoreOverrideForTesting<T>(
        _: StateStore?,
        operation: () throws -> T) rethrows -> T
    {
        try operation()
    }

    static func withStateStoreOverrideForTesting<T>(
        _: StateStore?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await operation()
    }
    #endif
}
#endif
