import Foundation

public enum ClaudeOAuthDelegatedRefreshCoordinator {
    private final class AttemptStateStorage: @unchecked Sendable {
        let lock = NSLock()
        let persistsCooldown: Bool
        var hasLoadedState = false
        var lastAttemptAt: Date?
        var lastCooldownInterval: TimeInterval?
        var inFlightAttemptID: UInt64?
        var inFlightTask: Task<Outcome, Never>?
        var nextAttemptID: UInt64 = 0

        init(persistsCooldown: Bool) {
            self.persistsCooldown = persistsCooldown
        }
    }

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

    private static let sharedState = AttemptStateStorage(persistsCooldown: true)

    public static func attempt(
        now: Date = Date(),
        timeout: TimeInterval = 8,
        environment: [String: String] = ProcessInfo.processInfo.environment) async -> Outcome
    {
        if Task.isCancelled {
            return .attemptedFailed("Cancelled.")
        }

        switch self.inFlightDecision(now: now, timeout: timeout, environment: environment) {
        case let .join(task):
            return await task.value
        case let .start(id, task, state):
            let outcome = await task.value
            self.clearInFlightTaskIfStillCurrent(id: id, state: state)
            return outcome
        }
    }

    private enum InFlightDecision {
        case join(Task<Outcome, Never>)
        case start(UInt64, Task<Outcome, Never>, AttemptStateStorage)
    }

    private struct AttemptConfiguration: Sendable {
        let environment: [String: String]
        let readStrategy: ClaudeOAuthKeychainReadStrategy
        let keychainAccessDisabled: Bool
        let securityCLIReadOverride: (@Sendable () -> Data?)?
        #if DEBUG
        let cliAvailableOverride: Bool?
        let touchAuthPathOverride: (@Sendable (TimeInterval, [String: String]) async throws -> Void)?
        let keychainFingerprintOverride: (@Sendable () -> ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?)?
        #endif
    }

    private static func inFlightDecision(
        now: Date,
        timeout: TimeInterval,
        environment: [String: String]) -> InFlightDecision
    {
        let state = self.currentStateStorage
        state.lock.lock()
        defer { state.lock.unlock() }

        if let existing = state.inFlightTask {
            return .join(existing)
        }

        state.nextAttemptID += 1
        let attemptID = state.nextAttemptID
        // Detached to avoid inheriting the caller's executor context (e.g. MainActor) and cancellation state.
        #if DEBUG
        let configuration = AttemptConfiguration(
            environment: environment,
            readStrategy: ClaudeOAuthKeychainReadStrategyPreference.current(),
            keychainAccessDisabled: KeychainAccessGate.isDisabled,
            securityCLIReadOverride: self.securityCLIReadOverrideSnapshot(),
            cliAvailableOverride: self.cliAvailableOverrideForTesting,
            touchAuthPathOverride: self.touchAuthPathOverrideForTesting,
            keychainFingerprintOverride: self.keychainFingerprintOverrideForTesting)
        #else
        let configuration = AttemptConfiguration(
            environment: environment,
            readStrategy: ClaudeOAuthKeychainReadStrategyPreference.current(),
            keychainAccessDisabled: KeychainAccessGate.isDisabled,
            securityCLIReadOverride: self.securityCLIReadOverrideSnapshot())
        #endif
        let task = Task.detached(priority: .utility) {
            await self.performAttempt(
                now: now,
                timeout: timeout,
                configuration: configuration,
                state: state)
        }
        state.inFlightAttemptID = attemptID
        state.inFlightTask = task
        return .start(attemptID, task, state)
    }

    private static func performAttempt(
        now: Date,
        timeout: TimeInterval,
        configuration: AttemptConfiguration,
        state: AttemptStateStorage) async -> Outcome
    {
        guard self.isClaudeCLIAvailable(environment: configuration.environment, configuration: configuration) else {
            self.log.info("Claude OAuth delegated refresh skipped: claude CLI unavailable")
            return .cliUnavailable
        }

        // Atomically reserve an attempt under the lock so concurrent callers don't race past isInCooldown() and start
        // multiple touches/poll loops.
        guard self.reserveAttemptIfNotInCooldown(now: now, state: state) else {
            self.log.debug("Claude OAuth delegated refresh skipped by cooldown")
            return .skippedByCooldown
        }

        let baseline = self.currentKeychainChangeObservationBaseline(
            readStrategy: configuration.readStrategy,
            keychainAccessDisabled: configuration.keychainAccessDisabled,
            securityCLIReadOverride: configuration.securityCLIReadOverride,
            configuration: configuration)
        var touchError: Error?

        do {
            try await self.touchOAuthAuthPath(
                timeout: timeout,
                environment: configuration.environment,
                configuration: configuration)
        } catch {
            touchError = error
        }

        // "Touch succeeded" must mean we actually observed the Claude keychain entry change.
        // Otherwise we end up in a long cooldown with still-expired credentials.
        let changed = await self.waitForClaudeKeychainChange(
            from: baseline,
            readStrategy: configuration.readStrategy,
            keychainAccessDisabled: configuration.keychainAccessDisabled,
            configuration: configuration,
            timeout: min(max(timeout, 1), 2))
        if changed {
            self.recordAttempt(now: now, cooldown: self.defaultCooldownInterval, state: state)
            self.log.info("Claude OAuth delegated refresh touch succeeded")
            return .attemptedSucceeded
        }

        self.recordAttempt(now: now, cooldown: self.shortCooldownInterval, state: state)
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
        let state = self.currentStateStorage
        state.lock.lock()
        defer { state.lock.unlock() }
        self.loadStateIfNeededLocked(state: state)
        guard let lastAttemptAt = state.lastAttemptAt else { return false }
        let cooldown = state.lastCooldownInterval ?? self.defaultCooldownInterval
        return now.timeIntervalSince(lastAttemptAt) < cooldown
    }

    public static func cooldownRemainingSeconds(now: Date = Date()) -> Int? {
        let state = self.currentStateStorage
        state.lock.lock()
        defer { state.lock.unlock() }
        self.loadStateIfNeededLocked(state: state)
        guard let lastAttemptAt = state.lastAttemptAt else { return nil }
        let cooldown = state.lastCooldownInterval ?? self.defaultCooldownInterval
        let remaining = cooldown - now.timeIntervalSince(lastAttemptAt)
        guard remaining > 0 else { return nil }
        return Int(remaining.rounded(.up))
    }

    public static func isClaudeCLIAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        self.isClaudeCLIAvailable(
            environment: environment,
            configuration: nil)
    }

    private static func isClaudeCLIAvailable(
        environment: [String: String],
        configuration: AttemptConfiguration?) -> Bool
    {
        #if DEBUG
        if let override = configuration?.cliAvailableOverride ?? self.cliAvailableOverrideForTesting {
            return override
        }
        #endif
        return ClaudeCLIResolver.isAvailable(environment: environment)
    }

    private static func touchOAuthAuthPath(
        timeout: TimeInterval,
        environment: [String: String],
        configuration: AttemptConfiguration?) async throws
    {
        #if DEBUG
        if let override = configuration?.touchAuthPathOverride ?? self.touchAuthPathOverrideForTesting {
            try await override(timeout, environment)
            return
        }
        #endif
        try await ClaudeStatusProbe.touchOAuthAuthPath(timeout: timeout, environment: environment)
    }

    private enum KeychainChangeObservationBaseline: Sendable {
        case securityFramework(fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?)
        case securityCLI(data: Data?)
    }

    private static func currentKeychainChangeObservationBaseline(
        readStrategy: ClaudeOAuthKeychainReadStrategy,
        keychainAccessDisabled: Bool,
        securityCLIReadOverride: (@Sendable () -> Data?)?,
        configuration: AttemptConfiguration?) -> KeychainChangeObservationBaseline
    {
        if readStrategy == .securityCLIExperimental {
            return .securityCLI(data: self.currentClaudeKeychainDataViaSecurityCLIForObservation(
                readStrategy: readStrategy,
                keychainAccessDisabled: keychainAccessDisabled,
                securityCLIReadOverride: securityCLIReadOverride))
        }
        return .securityFramework(fingerprint: self.currentClaudeKeychainFingerprint(configuration: configuration))
    }

    private static func waitForClaudeKeychainChange(
        from baseline: KeychainChangeObservationBaseline,
        readStrategy: ClaudeOAuthKeychainReadStrategy,
        keychainAccessDisabled: Bool,
        configuration: AttemptConfiguration?,
        timeout: TimeInterval) async -> Bool
    {
        // Prefer correctness but bound the delay. Keychain writes can be slightly delayed after the CLI touch.
        // Keep this short to avoid "prompt storms" on configurations where "no UI" queries can still surface UI.
        let clampedTimeout = max(0, min(timeout, 2))
        if clampedTimeout == 0 { return false }

        let delays: [TimeInterval] = [0.2, 0.5, 0.8].filter { $0 <= clampedTimeout }
        let deadline = Date().addingTimeInterval(clampedTimeout)

        func isObservedChange() -> Bool {
            switch baseline {
            case let .securityFramework(fingerprintBefore):
                // Treat "no fingerprint" as "not observed"; we only succeed if we can read a fingerprint and it
                // differs.
                guard let current = self.currentClaudeKeychainFingerprintForObservation(configuration: configuration)
                else {
                    return false
                }
                return current != fingerprintBefore
            case let .securityCLI(dataBefore):
                // In experimental mode, avoid Security.framework observation entirely and detect change from
                // /usr/bin/security output only.
                // If baseline capture failed (nil), treat observation as inconclusive and do not infer a change from
                // a later successful read.
                guard let dataBefore else { return false }
                guard let current = self.currentClaudeKeychainDataViaSecurityCLIForObservation(
                    readStrategy: readStrategy,
                    keychainAccessDisabled: keychainAccessDisabled,
                    securityCLIReadOverride: configuration?.securityCLIReadOverride)
                else { return false }
                return current != dataBefore
            }
        }

        if isObservedChange() {
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

            if isObservedChange() {
                return true
            }
        }

        return false
    }

    private static func currentClaudeKeychainFingerprint(
        configuration: AttemptConfiguration?) -> ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?
    {
        #if DEBUG
        if let override = configuration?.keychainFingerprintOverride ?? self.keychainFingerprintOverrideForTesting {
            return override()
        }
        #endif
        return ClaudeOAuthCredentialsStore.currentClaudeKeychainFingerprintWithoutPromptForAuthGate()
    }

    private static func currentClaudeKeychainFingerprintForObservation() -> ClaudeOAuthCredentialsStore
        .ClaudeKeychainFingerprint?
    {
        self.currentClaudeKeychainFingerprintForObservation(configuration: nil)
    }

    private static func currentClaudeKeychainFingerprintForObservation(
        configuration: AttemptConfiguration?) -> ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?
    {
        #if DEBUG
        if let override = configuration?.keychainFingerprintOverride ?? self.keychainFingerprintOverrideForTesting {
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

    private static func currentClaudeKeychainDataViaSecurityCLIForObservation(
        readStrategy: ClaudeOAuthKeychainReadStrategy,
        keychainAccessDisabled: Bool,
        securityCLIReadOverride: (@Sendable () -> Data?)?) -> Data?
    {
        guard !keychainAccessDisabled else { return nil }
        if let securityCLIReadOverride {
            return securityCLIReadOverride()
        }
        return ClaudeOAuthCredentialsStore.loadFromClaudeKeychainViaSecurityCLIIfEnabled(
            interaction: .background,
            readStrategy: readStrategy)
    }

    private static func securityCLIReadOverrideSnapshot() -> (@Sendable () -> Data?)? {
        #if DEBUG
        guard let override = ClaudeOAuthCredentialsStore.taskSecurityCLIReadOverride
            ?? ClaudeOAuthCredentialsStore.securityCLIReadOverride
        else {
            return nil
        }

        switch override {
        case let .data(data):
            return { data }
        case .timedOut, .nonZeroExit:
            return { nil }
        case let .dynamic(read):
            return { read(ClaudeOAuthCredentialsStore.SecurityCLIReadRequest(account: nil)) }
        }
        #else
        return nil
        #endif
    }

    private static func clearInFlightTaskIfStillCurrent(id: UInt64, state: AttemptStateStorage) {
        state.lock.lock()
        if state.inFlightAttemptID == id {
            state.inFlightAttemptID = nil
            state.inFlightTask = nil
        }
        state.lock.unlock()
    }

    private static func recordAttempt(now: Date, cooldown: TimeInterval, state: AttemptStateStorage) {
        state.lock.lock()
        defer { state.lock.unlock() }
        self.loadStateIfNeededLocked(state: state)
        state.lastAttemptAt = now
        state.lastCooldownInterval = cooldown
        guard state.persistsCooldown else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: self.cooldownDefaultsKey)
        UserDefaults.standard.set(cooldown, forKey: self.cooldownIntervalDefaultsKey)
    }

    private static func reserveAttemptIfNotInCooldown(now: Date, state: AttemptStateStorage) -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        self.loadStateIfNeededLocked(state: state)

        let cooldown = state.lastCooldownInterval ?? self.defaultCooldownInterval
        if let lastAttemptAt = state.lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < cooldown {
            return false
        }

        // Reserve with a short cooldown; the final outcome will extend or keep it short.
        state.lastAttemptAt = now
        state.lastCooldownInterval = self.shortCooldownInterval
        guard state.persistsCooldown else { return true }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: self.cooldownDefaultsKey)
        UserDefaults.standard.set(self.shortCooldownInterval, forKey: self.cooldownIntervalDefaultsKey)
        return true
    }

    private static func loadStateIfNeededLocked(state: AttemptStateStorage) {
        guard !state.hasLoadedState else { return }
        state.hasLoadedState = true
        guard state.persistsCooldown else {
            state.lastAttemptAt = nil
            state.lastCooldownInterval = nil
            return
        }
        guard let raw = UserDefaults.standard.object(forKey: self.cooldownDefaultsKey) as? Double else {
            state.lastAttemptAt = nil
            state.lastCooldownInterval = nil
            return
        }
        state.lastAttemptAt = Date(timeIntervalSince1970: raw)
        if let interval = UserDefaults.standard.object(forKey: self.cooldownIntervalDefaultsKey) as? Double {
            state.lastCooldownInterval = interval
        } else {
            state.lastCooldownInterval = nil
        }
    }

    #if DEBUG
    @TaskLocal private static var stateStorageForTesting: AttemptStateStorage?
    @TaskLocal static var cliAvailableOverrideForTesting: Bool?
    @TaskLocal static var touchAuthPathOverrideForTesting: (@Sendable (
        TimeInterval,
        [String: String]) async throws -> Void)?
    @TaskLocal static var keychainFingerprintOverrideForTesting: (@Sendable () -> ClaudeOAuthCredentialsStore
        .ClaudeKeychainFingerprint?)?

    static func withCLIAvailableOverrideForTesting<T>(
        _ override: Bool?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$cliAvailableOverrideForTesting.withValue(override) {
            try await operation()
        }
    }

    static func withTouchAuthPathOverrideForTesting<T>(
        _ override: (@Sendable (TimeInterval, [String: String]) async throws -> Void)?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$touchAuthPathOverrideForTesting.withValue(override) {
            try await operation()
        }
    }

    static func withKeychainFingerprintOverrideForTesting<T>(
        _ override: (@Sendable () -> ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?)?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$keychainFingerprintOverrideForTesting.withValue(override) {
            try await operation()
        }
    }

    static func withIsolatedStateForTesting<T>(operation: () async throws -> T) async rethrows -> T {
        let state = AttemptStateStorage(persistsCooldown: false)
        return try await self.$stateStorageForTesting.withValue(state) {
            try await operation()
        }
    }

    static func resetForTesting() {
        let state = self.currentStateStorage
        state.lock.lock()
        state.hasLoadedState = true
        state.lastAttemptAt = nil
        state.lastCooldownInterval = nil
        state.inFlightAttemptID = nil
        state.inFlightTask = nil
        state.nextAttemptID = 0
        state.lock.unlock()
        guard state.persistsCooldown else { return }
        UserDefaults.standard.removeObject(forKey: self.cooldownDefaultsKey)
        UserDefaults.standard.removeObject(forKey: self.cooldownIntervalDefaultsKey)
    }
    #endif

    private static var currentStateStorage: AttemptStateStorage {
        #if DEBUG
        self.stateStorageForTesting ?? self.sharedState
        #else
        self.sharedState
        #endif
    }
}
