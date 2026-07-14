import Foundation

#if os(macOS)
import os.lock

enum ClaudeCLIAuthPreflightGate {
    private struct State {
        var loaded = false
        var blockedUntil: Date?
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let blockedUntilKey = "claudeCLIAuthPreflightBlockedUntilV1"
    private static let timeoutCooldown: TimeInterval = 60 * 15
    private static let failureCooldown: TimeInterval = 60 * 15
    private static let log = CodexBarLog.logger(LogCategories.claudeCLI)

    #if DEBUG
    final class BlockedUntilStore: @unchecked Sendable {
        var blockedUntil: Date?

        init(blockedUntil: Date? = nil) {
            self.blockedUntil = blockedUntil
        }
    }

    @TaskLocal private static var taskStoreOverrideForTesting: BlockedUntilStore?
    #endif

    static func blockedUntil(
        interaction: ProviderInteraction = ProviderInteractionContext.current,
        now: Date = Date()) -> Date?
    {
        guard interaction != .userInitiated else { return nil }
        #if DEBUG
        if let store = self.taskStoreOverrideForTesting {
            return self.activeBlockedUntil(store.blockedUntil, now: now) { store.blockedUntil = $0 }
        }
        #endif
        return self.lock.withLock { state in
            self.loadIfNeeded(&state)
            return self.activeBlockedUntil(state.blockedUntil, now: now) {
                state.blockedUntil = $0
                self.persist(state)
            }
        }
    }

    static func recordTimeout(now: Date = Date()) {
        self.recordBlocked(until: now.addingTimeInterval(self.timeoutCooldown), reason: "timeout")
    }

    static func recordFailure(now: Date = Date()) {
        self.recordBlocked(until: now.addingTimeInterval(self.failureCooldown), reason: "failure")
    }

    @discardableResult
    static func clear(now: Date = Date()) -> Bool {
        #if DEBUG
        if let store = self.taskStoreOverrideForTesting {
            let wasBlocked = store.blockedUntil.map { $0 > now } ?? false
            store.blockedUntil = nil
            return wasBlocked
        }
        #endif
        return self.lock.withLock { state in
            self.loadIfNeeded(&state)
            let wasBlocked = state.blockedUntil.map { $0 > now } ?? false
            guard state.blockedUntil != nil else { return false }
            state.blockedUntil = nil
            self.persist(state)
            return wasBlocked
        }
    }

    #if DEBUG
    static func withBlockedUntilStoreOverrideForTesting<T>(
        _ store: BlockedUntilStore?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskStoreOverrideForTesting.withValue(store) {
            try await operation()
        }
    }

    static func resetForTesting() {
        self.lock.withLock { state in
            state.loaded = true
            state.blockedUntil = nil
            UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
        }
    }

    static var blockedUntilKeyForTesting: String {
        self.blockedUntilKey
    }

    static func reloadPersistedStateForTesting() {
        self.lock.withLock { state in
            state.loaded = false
            state.blockedUntil = nil
        }
    }
    #endif

    private static func activeBlockedUntil(
        _ blockedUntil: Date?,
        now: Date,
        update: (Date?) -> Void) -> Date?
    {
        guard let blockedUntil else { return nil }
        guard blockedUntil > now else {
            update(nil)
            return nil
        }
        return blockedUntil
    }

    private static func recordBlocked(until: Date, reason: String) {
        #if DEBUG
        if let store = self.taskStoreOverrideForTesting {
            store.blockedUntil = until
            return
        }
        #endif
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            state.blockedUntil = until
            self.persist(state)
        }
        self.log.warning(
            "Claude CLI background auth preflight paused",
            metadata: [
                "reason": reason,
                "until": "\(until.timeIntervalSince1970)",
            ])
    }

    private static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        if let raw = UserDefaults.standard.object(forKey: self.blockedUntilKey) as? Double {
            state.blockedUntil = Date(timeIntervalSince1970: raw)
        }
    }

    private static func persist(_ state: State) {
        if let blockedUntil = state.blockedUntil {
            UserDefaults.standard.set(blockedUntil.timeIntervalSince1970, forKey: self.blockedUntilKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.blockedUntilKey)
        }
    }
}
#else
enum ClaudeCLIAuthPreflightGate {
    static func blockedUntil(
        interaction _: ProviderInteraction = ProviderInteractionContext.current,
        now _: Date = Date()) -> Date?
    {
        nil
    }

    static func recordTimeout(now _: Date = Date()) {}
    static func recordFailure(now _: Date = Date()) {}

    @discardableResult
    static func clear(now _: Date = Date()) -> Bool {
        false
    }

    #if DEBUG
    static func resetForTesting() {}
    #endif
}
#endif
