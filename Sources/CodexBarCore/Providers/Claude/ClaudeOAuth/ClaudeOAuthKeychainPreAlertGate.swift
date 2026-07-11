import Foundation

#if os(macOS)
import os.lock

enum ClaudeOAuthKeychainPreAlertGate {
    fileprivate struct State {
        var loaded = false
        var acknowledgedUntil: Date?
        var presentationInFlight = false
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let defaultsKey = "claudeOAuthKeychainPreAlertAcknowledgedUntilV1"
    static let cooldownInterval: TimeInterval = 60 * 60 * 6

    #if DEBUG
    final class StateStore: @unchecked Sendable {
        fileprivate let lock = OSAllocatedUnfairLock<State>(initialState: State(loaded: true))
    }

    @TaskLocal private static var taskStateStoreOverrideForTesting: StateStore?
    #endif

    /// Presents at most one explanatory alert and starts the cooldown only when it reaches a handler.
    @discardableResult
    static func presentIfNeeded(
        now: Date = Date(),
        completedAt: Date? = nil,
        present: () -> Bool) -> Bool
    {
        guard self.beginPresentation(now: now) else { return false }
        let wasPresented = present()
        self.finishPresentation(wasPresented: wasPresented, now: completedAt ?? Date())
        return wasPresented
    }

    private static func beginPresentation(now: Date) -> Bool {
        #if DEBUG
        if let store = self.taskStateStoreOverrideForTesting {
            return store.lock.withLock { state in
                self.reservePresentation(state: &state, now: now)
            }
        }
        #endif
        return self.lock.withLock { state in
            self.loadIfNeeded(&state)
            guard self.reservePresentation(state: &state, now: now) else { return false }
            self.persist(state)
            return true
        }
    }

    private static func finishPresentation(wasPresented: Bool, now: Date) {
        #if DEBUG
        if let store = self.taskStateStoreOverrideForTesting {
            store.lock.withLock { state in
                self.completePresentation(state: &state, wasPresented: wasPresented, now: now)
            }
            return
        }
        #endif
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            self.completePresentation(state: &state, wasPresented: wasPresented, now: now)
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

    private static func reservePresentation(state: inout State, now: Date) -> Bool {
        guard !state.presentationInFlight else { return false }
        if let acknowledgedUntil = state.acknowledgedUntil, acknowledgedUntil > now {
            return false
        }
        state.acknowledgedUntil = nil
        state.presentationInFlight = true
        return true
    }

    private static func completePresentation(state: inout State, wasPresented: Bool, now: Date) {
        state.presentationInFlight = false
        if wasPresented {
            state.acknowledgedUntil = now.addingTimeInterval(self.cooldownInterval)
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

    @discardableResult
    static func presentIfNeeded(
        now _: Date = Date(),
        completedAt _: Date? = nil,
        present _: () -> Bool) -> Bool
    {
        false
    }

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
