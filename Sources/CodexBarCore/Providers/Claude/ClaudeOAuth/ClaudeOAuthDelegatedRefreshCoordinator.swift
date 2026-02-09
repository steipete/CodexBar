import Foundation

public enum ClaudeOAuthDelegatedRefreshCoordinator {
    public enum Outcome: Sendable, Equatable {
        case skippedByCooldown
        case cliUnavailable
        case attemptedSucceeded
        case attemptedFailed(String)
    }

    private static let log = CodexBarLog.logger(LogCategories.claudeUsage)
    private static let cooldownDefaultsKey = "claudeOAuthDelegatedRefreshLastAttemptAtV1"
    private static let cooldownIntervalDefaultsKey = "claudeOAuthDelegatedRefreshCooldownIntervalSecondsV1"
    private static let defaultCooldownInterval: TimeInterval = 60 * 5
    private static let shortCooldownInterval: TimeInterval = 20

    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var hasLoadedState = false
    private nonisolated(unsafe) static var lastAttemptAt: Date?
    private nonisolated(unsafe) static var lastCooldownInterval: TimeInterval?
    private nonisolated(unsafe) static var inFlightAttemptID: UInt64?
    private nonisolated(unsafe) static var inFlightTask: Task<Outcome, Never>?
    private nonisolated(unsafe) static var nextAttemptID: UInt64 = 0

    public static func attempt(now: Date = Date(), timeout: TimeInterval = 8) async -> Outcome {
        if Task.isCancelled {
            return .attemptedFailed("Cancelled.")
        }

        switch self.inFlightDecision(now: now, timeout: timeout) {
        case let .join(task):
            return await task.value
        case let .start(id, task):
            let outcome = await task.value
            self.clearInFlightTaskIfStillCurrent(id: id)
            return outcome
        }
    }

    private enum InFlightDecision {
        case join(Task<Outcome, Never>)
        case start(UInt64, Task<Outcome, Never>)
    }

    private static func inFlightDecision(now: Date, timeout: TimeInterval) -> InFlightDecision {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }

        if let existing = self.inFlightTask {
            return .join(existing)
        }

        self.nextAttemptID += 1
        let attemptID = self.nextAttemptID
        // Detached to avoid inheriting the caller's executor context (e.g. MainActor) and cancellation state.
        let task = Task.detached(priority: .utility) { await self.performAttempt(now: now, timeout: timeout) }
        self.inFlightAttemptID = attemptID
        self.inFlightTask = task
        return .start(attemptID, task)
    }

    private static func performAttempt(now: Date, timeout: TimeInterval) async -> Outcome {
        guard self.isClaudeCLIAvailable() else {
            self.log.info("Claude OAuth delegated refresh skipped: claude CLI unavailable")
            return .cliUnavailable
        }

        // Atomically reserve an attempt under the lock so concurrent callers don't race past isInCooldown() and start
        // multiple touches/poll loops.
        guard self.reserveAttemptIfNotInCooldown(now: now) else {
            self.log.debug("Claude OAuth delegated refresh skipped by cooldown")
            return .skippedByCooldown
        }

        let fingerprintBefore = self.currentClaudeKeychainFingerprint()
        var touchError: Error?

        do {
            try await self.touchOAuthAuthPath(timeout: timeout)
        } catch {
            touchError = error
        }

        // "Touch succeeded" must mean we actually observed the Claude keychain entry change.
        // Otherwise we end up in a long cooldown with still-expired credentials.
        let changed = await self.waitForClaudeKeychainChange(
            from: fingerprintBefore,
            timeout: min(max(timeout, 1), 2))
        if changed {
            self.recordAttempt(now: now, cooldown: self.defaultCooldownInterval)
            self.log.info("Claude OAuth delegated refresh touch succeeded")
            return .attemptedSucceeded
        }

        self.recordAttempt(now: now, cooldown: self.shortCooldownInterval)
        if let touchError {
            let errorType = String(describing: type(of: touchError))
            self.log.warning(
                "Claude OAuth delegated refresh touch failed",
                metadata: ["errorType": errorType])
            self.log.debug("Claude OAuth delegated refresh touch error: \(touchError.localizedDescription)")
            return .attemptedFailed(touchError.localizedDescription)
        }

        self.log.warning("Claude OAuth delegated refresh touch did not update Claude keychain")
        return .attemptedFailed("Claude keychain did not update after Claude CLI touch.")
    }

    public static func isInCooldown(now: Date = Date()) -> Bool {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.loadStateIfNeededLocked()
        guard let lastAttemptAt = self.lastAttemptAt else { return false }
        let cooldown = self.lastCooldownInterval ?? self.defaultCooldownInterval
        return now.timeIntervalSince(lastAttemptAt) < cooldown
    }

    public static func cooldownRemainingSeconds(now: Date = Date()) -> Int? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.loadStateIfNeededLocked()
        guard let lastAttemptAt = self.lastAttemptAt else { return nil }
        let cooldown = self.lastCooldownInterval ?? self.defaultCooldownInterval
        let remaining = cooldown - now.timeIntervalSince(lastAttemptAt)
        guard remaining > 0 else { return nil }
        return Int(remaining.rounded(.up))
    }

    public static func isClaudeCLIAvailable() -> Bool {
        #if DEBUG
        if let override = self.cliAvailableOverride {
            return override
        }
        #endif
        return ClaudeStatusProbe.isClaudeBinaryAvailable()
    }

    private static func touchOAuthAuthPath(timeout: TimeInterval) async throws {
        #if DEBUG
        if let override = self.touchAuthPathOverride {
            try await override(timeout)
            return
        }
        #endif
        try await ClaudeStatusProbe.touchOAuthAuthPath(timeout: timeout)
    }

    private static func waitForClaudeKeychainChange(
        from fingerprintBefore: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?,
        timeout: TimeInterval) async -> Bool
    {
        // Prefer correctness but bound the delay. Keychain writes can be slightly delayed after the CLI touch.
        // Keep this short to avoid "prompt storms" on configurations where "no UI" queries can still surface UI.
        let clampedTimeout = max(0, min(timeout, 2))
        if clampedTimeout == 0 { return false }

        let delays: [TimeInterval] = [0.2, 0.5, 0.8].filter { $0 <= clampedTimeout }
        let deadline = Date().addingTimeInterval(clampedTimeout)

        func isObservedChange(_ current: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?) -> Bool {
            // Treat "no fingerprint" as "not observed"; we only succeed if we can read a fingerprint and it differs.
            guard let current else { return false }
            return current != fingerprintBefore
        }

        if isObservedChange(self.currentClaudeKeychainFingerprintForObservation()) {
            return true
        }

        for delay in delays {
            if Date() >= deadline { break }
            do {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return false
            }

            if isObservedChange(self.currentClaudeKeychainFingerprintForObservation()) {
                return true
            }
        }

        return false
    }

    private static func currentClaudeKeychainFingerprint() -> ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint? {
        #if DEBUG
        if let override = self.keychainFingerprintOverride {
            return override()
        }
        #endif
        return ClaudeOAuthCredentialsStore.currentClaudeKeychainFingerprintWithoutPromptForAuthGate()
    }

    private static func currentClaudeKeychainFingerprintForObservation() -> ClaudeOAuthCredentialsStore
        .ClaudeKeychainFingerprint?
    {
        #if DEBUG
        if let override = self.keychainFingerprintOverride {
            return override()
        }
        #endif

        // Observation should not be blocked by the background cooldown gate; otherwise we can "false fail" even when
        // the CLI refreshed successfully but we couldn't observe it due to a previous denied prompt/cooldown.
        //
        // This temporarily classifies the observation query as "user initiated" so it bypasses the gate that only
        // applies to background probes. The query remains "no UI" and does not clear cooldown state itself.
        return ProviderInteractionContext.$current.withValue(.userInitiated) {
            ClaudeOAuthCredentialsStore.currentClaudeKeychainFingerprintWithoutPromptForAuthGate()
        }
    }

    private static func clearInFlightTaskIfStillCurrent(id: UInt64) {
        self.stateLock.lock()
        if self.inFlightAttemptID == id {
            self.inFlightAttemptID = nil
            self.inFlightTask = nil
        }
        self.stateLock.unlock()
    }

    private static func recordAttempt(now: Date, cooldown: TimeInterval) {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.loadStateIfNeededLocked()
        self.lastAttemptAt = now
        self.lastCooldownInterval = cooldown
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: self.cooldownDefaultsKey)
        UserDefaults.standard.set(cooldown, forKey: self.cooldownIntervalDefaultsKey)
    }

    private static func reserveAttemptIfNotInCooldown(now: Date) -> Bool {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.loadStateIfNeededLocked()

        let cooldown = self.lastCooldownInterval ?? self.defaultCooldownInterval
        if let lastAttemptAt = self.lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < cooldown {
            return false
        }

        // Reserve with a short cooldown; the final outcome will extend or keep it short.
        self.lastAttemptAt = now
        self.lastCooldownInterval = self.shortCooldownInterval
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: self.cooldownDefaultsKey)
        UserDefaults.standard.set(self.shortCooldownInterval, forKey: self.cooldownIntervalDefaultsKey)
        return true
    }

    private static func loadStateIfNeededLocked() {
        guard !self.hasLoadedState else { return }
        self.hasLoadedState = true
        guard let raw = UserDefaults.standard.object(forKey: self.cooldownDefaultsKey) as? Double else {
            self.lastAttemptAt = nil
            self.lastCooldownInterval = nil
            return
        }
        self.lastAttemptAt = Date(timeIntervalSince1970: raw)
        if let interval = UserDefaults.standard.object(forKey: self.cooldownIntervalDefaultsKey) as? Double {
            self.lastCooldownInterval = interval
        } else {
            self.lastCooldownInterval = nil
        }
    }

    #if DEBUG
    private nonisolated(unsafe) static var cliAvailableOverride: Bool?
    private nonisolated(unsafe) static var touchAuthPathOverride: (@Sendable (TimeInterval) async throws -> Void)?
    private nonisolated(unsafe) static var keychainFingerprintOverride: (() -> ClaudeOAuthCredentialsStore
        .ClaudeKeychainFingerprint?)?

    static func setCLIAvailableOverrideForTesting(_ override: Bool?) {
        self.cliAvailableOverride = override
    }

    static func setTouchAuthPathOverrideForTesting(_ override: (@Sendable (TimeInterval) async throws -> Void)?) {
        self.touchAuthPathOverride = override
    }

    static func setKeychainFingerprintOverrideForTesting(
        _ override: (() -> ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?)?)
    {
        self.keychainFingerprintOverride = override
    }

    static func resetForTesting() {
        self.stateLock.lock()
        self.hasLoadedState = true
        self.lastAttemptAt = nil
        self.lastCooldownInterval = nil
        self.inFlightAttemptID = nil
        self.inFlightTask = nil
        self.nextAttemptID = 0
        self.stateLock.unlock()
        UserDefaults.standard.removeObject(forKey: self.cooldownDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.cooldownIntervalDefaultsKey)
        self.cliAvailableOverride = nil
        self.touchAuthPathOverride = nil
        self.keychainFingerprintOverride = nil
    }
    #endif
}
