import Foundation

public enum ClaudeOAuthDelegatedRefreshCoordinator {
    private struct CooldownState {
        var lastAttemptAt: Date?
        var interval: TimeInterval?
    }

    private final class AttemptStateStorage: @unchecked Sendable {
        let lock = NSLock()
        let persistsCooldown: Bool
        var loadedCooldownProfiles: Set<String> = []
        var cooldownByProfile: [String: CooldownState] = [:]
        var inFlightAttemptID: UInt64?
        var inFlightInteraction: ProviderInteraction?
        var inFlightProfileIdentifier: String?
        var inFlightTask: Task<Outcome, Never>?
        var nextAttemptID: UInt64 = 0

        init(persistsCooldown: Bool) {
            self.persistsCooldown = persistsCooldown
        }
    }

    public enum Outcome: Sendable, Equatable {
        case skippedByCooldown
        case skippedByPromptPolicy
        case cliUnavailable
        case attemptedSucceeded
        case attemptedFailed(String)
    }

    private static let log = CodexBarLog.logger(LogCategories.claudeUsage)
    private static let cooldownDefaultsKey = "claudeOAuthDelegatedRefreshLastAttemptAtV1"
    private static let cooldownIntervalDefaultsKey = "claudeOAuthDelegatedRefreshCooldownIntervalSecondsV1"
    private static let cooldownProfileKeySeparator = ".profile."
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

        let decision = self.inFlightDecision(
            now: now,
            timeout: timeout,
            environment: environment,
            interaction: ProviderInteractionContext.current)
        #if DEBUG
        if case .joinThenRetry = decision {
            self.userInitiatedBackgroundJoinObserverForTesting?()
        }
        if case .joinDifferentProfileThenRetry = decision {
            self.differentProfileJoinObserverForTesting?()
        }
        #endif

        switch decision {
        case let .join(task):
            return await task.value
        case let .joinThenRetry(id, task, state):
            let outcome = await task.value
            self.clearInFlightTaskIfStillCurrent(id: id, state: state)
            switch outcome {
            case .attemptedFailed, .skippedByCooldown, .skippedByPromptPolicy, .cliUnavailable:
                return await self.attempt(now: now, timeout: timeout, environment: environment)
            case .attemptedSucceeded:
                return outcome
            }
        case let .joinDifferentProfileThenRetry(id, task, state):
            _ = await task.value
            self.clearInFlightTaskIfStillCurrent(id: id, state: state)
            return await self.attempt(now: now, timeout: timeout, environment: environment)
        case let .start(id, task, state):
            let outcome = await task.value
            self.clearInFlightTaskIfStillCurrent(id: id, state: state)
            return outcome
        }
    }

    private enum InFlightDecision {
        case join(Task<Outcome, Never>)
        case joinThenRetry(UInt64, Task<Outcome, Never>, AttemptStateStorage)
        case joinDifferentProfileThenRetry(UInt64, Task<Outcome, Never>, AttemptStateStorage)
        case start(UInt64, Task<Outcome, Never>, AttemptStateStorage)
    }

    private struct AttemptConfiguration {
        let environment: [String: String]
        let profileIdentifier: String
        let interaction: ProviderInteraction
        let readStrategy: ClaudeOAuthKeychainReadStrategy
        let promptMode: ClaudeOAuthKeychainPromptMode
        let keychainAccessDisabled: Bool
        let hasSelectedProfileOAuthCredentialsFile: Bool
        #if DEBUG
        let cliAvailableOverride: Bool?
        let touchAuthPathOverride: (@Sendable (TimeInterval, [String: String]) async throws -> Void)?
        let keychainFingerprintOverride: (@Sendable () -> ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?)?
        #endif
    }

    private static func inFlightDecision(
        now: Date,
        timeout: TimeInterval,
        environment: [String: String],
        interaction: ProviderInteraction) -> InFlightDecision
    {
        let state = self.currentStateStorage
        let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
        state.lock.lock()
        defer { state.lock.unlock() }

        if let existing = state.inFlightTask {
            if state.inFlightProfileIdentifier != profileIdentifier,
               let existingID = state.inFlightAttemptID
            {
                return .joinDifferentProfileThenRetry(existingID, existing, state)
            }
            if interaction == .userInitiated,
               state.inFlightInteraction != .userInitiated,
               let existingID = state.inFlightAttemptID
            {
                return .joinThenRetry(existingID, existing, state)
            }
            return .join(existing)
        }

        state.nextAttemptID += 1
        let attemptID = state.nextAttemptID
        // Detached to avoid inheriting the caller's executor context (e.g. MainActor) and cancellation state.
        #if DEBUG
        let readStrategy = ClaudeOAuthKeychainReadStrategyPreference.current()
        let configuration = AttemptConfiguration(
            environment: environment,
            profileIdentifier: profileIdentifier,
            interaction: interaction,
            readStrategy: readStrategy,
            // The delegated Claude process is an opaque Keychain boundary. Its policy must come
            // from the user's stored preference, not the strategy-adjusted mode used by our own reads.
            promptMode: ClaudeOAuthKeychainPromptPreference.storedMode(),
            keychainAccessDisabled: KeychainAccessGate.isDisabled,
            hasSelectedProfileOAuthCredentialsFile: ClaudeOAuthCredentialsStore
                .hasSelectedProfileOAuthCredentialsFile(environment: environment),
            cliAvailableOverride: self.cliAvailableOverrideForTesting,
            touchAuthPathOverride: self.touchAuthPathOverrideForTesting,
            keychainFingerprintOverride: self.keychainFingerprintOverrideForTesting)
        let securityCLIReadOverride = ClaudeOAuthCredentialsStore.currentSecurityCLIReadOverrideForTesting()
        #else
        let readStrategy = ClaudeOAuthKeychainReadStrategyPreference.current()
        let configuration = AttemptConfiguration(
            environment: environment,
            profileIdentifier: profileIdentifier,
            interaction: interaction,
            readStrategy: readStrategy,
            // The delegated Claude process is an opaque Keychain boundary. Its policy must come
            // from the user's stored preference, not the strategy-adjusted mode used by our own reads.
            promptMode: ClaudeOAuthKeychainPromptPreference.storedMode(),
            keychainAccessDisabled: KeychainAccessGate.isDisabled,
            hasSelectedProfileOAuthCredentialsFile: ClaudeOAuthCredentialsStore
                .hasSelectedProfileOAuthCredentialsFile(environment: environment))
        #endif
        let task = Task.detached(priority: .utility) {
            #if DEBUG
            return await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(configuration.promptMode) {
                await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(securityCLIReadOverride) {
                    await self.performAttempt(
                        now: now,
                        timeout: timeout,
                        configuration: configuration,
                        state: state)
                }
            }
            #else
            await self.performAttempt(
                now: now,
                timeout: timeout,
                configuration: configuration,
                state: state)
            #endif
        }
        state.inFlightAttemptID = attemptID
        state.inFlightInteraction = interaction
        state.inFlightProfileIdentifier = profileIdentifier
        state.inFlightTask = task
        return .start(attemptID, task, state)
    }

    private static func performAttempt(
        now: Date,
        timeout: TimeInterval,
        configuration: AttemptConfiguration,
        state: AttemptStateStorage) async -> Outcome
    {
        let profileIdentifier = configuration.profileIdentifier

        // `/status` is an opaque Claude CLI invocation and may launch `/usr/bin/security` outside
        // CodexBar's own no-UI query controls. Background work may not cross that boundary unless
        // the user explicitly opted into always allowing Keychain access.
        if configuration.interaction == .background,
           configuration.keychainAccessDisabled || configuration.promptMode != .always
        {
            self.log.info("Claude OAuth delegated refresh skipped by Keychain prompt policy")
            return .skippedByPromptPolicy
        }

        guard self.isClaudeCLIAvailable(environment: configuration.environment, configuration: configuration) else {
            self.log.info("Claude OAuth delegated refresh skipped: claude CLI unavailable")
            return .cliUnavailable
        }

        // Atomically reserve an attempt under the lock so concurrent callers don't race past isInCooldown() and start
        // multiple touches/poll loops.
        guard self.reserveAttemptIfNotInCooldown(
            now: now,
            bypassCooldown: configuration.interaction == .userInitiated,
            profileIdentifier: profileIdentifier,
            state: state)
        else {
            self.log.debug("Claude OAuth delegated refresh skipped by cooldown")
            return .skippedByCooldown
        }

        if let mcpOAuthOnlyFailure = self.mcpOAuthOnlyKeychainFailureIfPresent(
            interaction: configuration.interaction,
            readStrategy: configuration.readStrategy,
            keychainAccessDisabled: configuration.keychainAccessDisabled,
            hasSelectedProfileOAuthCredentialsFile: configuration.hasSelectedProfileOAuthCredentialsFile,
            environment: configuration.environment)
        {
            self.recordAttempt(
                now: now,
                cooldown: self.defaultCooldownInterval,
                profileIdentifier: profileIdentifier,
                state: state)
            self.log.warning(
                "Claude OAuth delegated refresh skipped: Claude keychain has MCP OAuth state only",
                metadata: ["readStrategy": configuration.readStrategy.rawValue])
            return .attemptedFailed(mcpOAuthOnlyFailure)
        }

        let baseline = self.currentKeychainChangeObservationBaseline(
            readStrategy: configuration.readStrategy,
            keychainAccessDisabled: configuration.keychainAccessDisabled,
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
            self.recordAttempt(
                now: now,
                cooldown: self.defaultCooldownInterval,
                profileIdentifier: profileIdentifier,
                state: state)
            self.log.info("Claude OAuth delegated refresh touch succeeded")
            return .attemptedSucceeded
        }

        self.recordAttempt(
            now: now,
            cooldown: self.shortCooldownInterval,
            profileIdentifier: profileIdentifier,
            state: state)
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

    public static func isInCooldown(
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        let state = self.currentStateStorage
        let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
        state.lock.lock()
        defer { state.lock.unlock() }
        self.loadCooldownIfNeededLocked(profileIdentifier: profileIdentifier, state: state)
        guard let lastAttemptAt = state.cooldownByProfile[profileIdentifier]?.lastAttemptAt else { return false }
        let cooldown = state.cooldownByProfile[profileIdentifier]?.interval ?? self.defaultCooldownInterval
        return now.timeIntervalSince(lastAttemptAt) < cooldown
    }

    public static func cooldownRemainingSeconds(
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Int?
    {
        let state = self.currentStateStorage
        let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
        state.lock.lock()
        defer { state.lock.unlock() }
        self.loadCooldownIfNeededLocked(profileIdentifier: profileIdentifier, state: state)
        guard let lastAttemptAt = state.cooldownByProfile[profileIdentifier]?.lastAttemptAt else { return nil }
        let cooldown = state.cooldownByProfile[profileIdentifier]?.interval ?? self.defaultCooldownInterval
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

    private enum KeychainChangeObservationBaseline {
        case securityFramework(fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?)
        case securityCLI(data: Data?)
    }

    private static func currentKeychainChangeObservationBaseline(
        readStrategy: ClaudeOAuthKeychainReadStrategy,
        keychainAccessDisabled: Bool,
        configuration: AttemptConfiguration?) -> KeychainChangeObservationBaseline
    {
        if readStrategy == .securityCLIExperimental {
            return .securityCLI(data: self.currentClaudeKeychainDataViaSecurityCLIForObservation(
                readStrategy: readStrategy,
                keychainAccessDisabled: keychainAccessDisabled,
                interaction: .background))
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
                    interaction: .background)
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
        interaction: ProviderInteraction) -> Data?
    {
        guard !keychainAccessDisabled else { return nil }
        return ClaudeOAuthCredentialsStore.readRawClaudeKeychainPayloadViaSecurityCLIIfEnabled(
            interaction: interaction,
            readStrategy: readStrategy)
    }

    private static func mcpOAuthOnlyKeychainFailureIfPresent(
        interaction: ProviderInteraction,
        readStrategy: ClaudeOAuthKeychainReadStrategy,
        keychainAccessDisabled: Bool,
        hasSelectedProfileOAuthCredentialsFile: Bool,
        environment: [String: String]) -> String?
    {
        guard interaction != .userInitiated else { return nil }
        guard !hasSelectedProfileOAuthCredentialsFile else { return nil }
        guard ClaudeOAuthCredentialsStore.isMcpOAuthOnlyClaudeKeychainPayloadPresent(
            interaction: interaction,
            readStrategy: readStrategy,
            keychainAccessDisabled: keychainAccessDisabled,
            environment: environment)
        else {
            return nil
        }
        return ClaudeOAuthCredentialsError.mcpOAuthOnlyKeychain.errorDescription
            ?? "Claude keychain contains MCP OAuth state only."
    }

    private static func clearInFlightTaskIfStillCurrent(id: UInt64, state: AttemptStateStorage) {
        state.lock.lock()
        if state.inFlightAttemptID == id {
            state.inFlightAttemptID = nil
            state.inFlightInteraction = nil
            state.inFlightProfileIdentifier = nil
            state.inFlightTask = nil
        }
        state.lock.unlock()
    }

    private static func recordAttempt(
        now: Date,
        cooldown: TimeInterval,
        profileIdentifier: String,
        state: AttemptStateStorage)
    {
        state.lock.lock()
        defer { state.lock.unlock() }
        self.loadCooldownIfNeededLocked(profileIdentifier: profileIdentifier, state: state)
        state.cooldownByProfile[profileIdentifier] = CooldownState(lastAttemptAt: now, interval: cooldown)
        guard state.persistsCooldown else { return }
        let defaults = UserDefaults.standard
        defaults.set(
            now.timeIntervalSince1970,
            forKey: self.profileKey(self.cooldownDefaultsKey, profileIdentifier: profileIdentifier))
        defaults.set(
            cooldown,
            forKey: self.profileKey(self.cooldownIntervalDefaultsKey, profileIdentifier: profileIdentifier))
        self.removeLegacyCooldownIfDefaultProfile(profileIdentifier, defaults: defaults)
    }

    private static func reserveAttemptIfNotInCooldown(
        now: Date,
        bypassCooldown: Bool,
        profileIdentifier: String,
        state: AttemptStateStorage) -> Bool
    {
        state.lock.lock()
        defer { state.lock.unlock() }
        self.loadCooldownIfNeededLocked(profileIdentifier: profileIdentifier, state: state)

        let profileState = state.cooldownByProfile[profileIdentifier]
        let cooldown = profileState?.interval ?? self.defaultCooldownInterval
        if !bypassCooldown,
           let lastAttemptAt = profileState?.lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < cooldown
        {
            return false
        }

        // Reserve with a short cooldown; the final outcome will extend or keep it short.
        state.cooldownByProfile[profileIdentifier] = CooldownState(
            lastAttemptAt: now,
            interval: self.shortCooldownInterval)
        guard state.persistsCooldown else { return true }
        let defaults = UserDefaults.standard
        defaults.set(
            now.timeIntervalSince1970,
            forKey: self.profileKey(self.cooldownDefaultsKey, profileIdentifier: profileIdentifier))
        defaults.set(
            self.shortCooldownInterval,
            forKey: self.profileKey(self.cooldownIntervalDefaultsKey, profileIdentifier: profileIdentifier))
        self.removeLegacyCooldownIfDefaultProfile(profileIdentifier, defaults: defaults)
        return true
    }

    private static func loadCooldownIfNeededLocked(
        profileIdentifier: String,
        state: AttemptStateStorage)
    {
        guard state.loadedCooldownProfiles.insert(profileIdentifier).inserted else { return }
        guard state.persistsCooldown else {
            state.cooldownByProfile[profileIdentifier] = CooldownState()
            return
        }

        let defaults = UserDefaults.standard
        let timestampKey = self.profileKey(self.cooldownDefaultsKey, profileIdentifier: profileIdentifier)
        let intervalKey = self.profileKey(self.cooldownIntervalDefaultsKey, profileIdentifier: profileIdentifier)
        let defaultProfileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
            environment: ProcessInfo.processInfo.environment)
        let shouldMigrateLegacy = profileIdentifier == defaultProfileIdentifier
            && defaults.object(forKey: timestampKey) == nil
            && defaults.object(forKey: self.cooldownDefaultsKey) != nil
        let storedTimestampKey = shouldMigrateLegacy ? self.cooldownDefaultsKey : timestampKey
        let storedIntervalKey = shouldMigrateLegacy ? self.cooldownIntervalDefaultsKey : intervalKey

        guard let raw = defaults.object(forKey: storedTimestampKey) as? Double else {
            state.cooldownByProfile[profileIdentifier] = CooldownState()
            return
        }

        let cooldown = CooldownState(
            lastAttemptAt: Date(timeIntervalSince1970: raw),
            interval: defaults.object(forKey: storedIntervalKey) as? Double)
        state.cooldownByProfile[profileIdentifier] = cooldown
        if shouldMigrateLegacy {
            defaults.set(raw, forKey: timestampKey)
            if let interval = cooldown.interval {
                defaults.set(interval, forKey: intervalKey)
            }
            self.removeLegacyCooldownIfDefaultProfile(profileIdentifier, defaults: defaults)
        }
    }

    private static func profileKey(_ base: String, profileIdentifier: String) -> String {
        base + self.cooldownProfileKeySeparator + profileIdentifier
    }

    private static func removeLegacyCooldownIfDefaultProfile(
        _ profileIdentifier: String,
        defaults: UserDefaults)
    {
        let defaultProfileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
            environment: ProcessInfo.processInfo.environment)
        guard profileIdentifier == defaultProfileIdentifier else { return }
        defaults.removeObject(forKey: self.cooldownDefaultsKey)
        defaults.removeObject(forKey: self.cooldownIntervalDefaultsKey)
    }

    #if DEBUG
    @TaskLocal private static var stateStorageForTesting: AttemptStateStorage?
    @TaskLocal static var cliAvailableOverrideForTesting: Bool?
    @TaskLocal static var touchAuthPathOverrideForTesting: (@Sendable (
        TimeInterval,
        [String: String]) async throws -> Void)?
    @TaskLocal static var keychainFingerprintOverrideForTesting: (@Sendable () -> ClaudeOAuthCredentialsStore
        .ClaudeKeychainFingerprint?)?
    @TaskLocal static var userInitiatedBackgroundJoinObserverForTesting: (@Sendable () -> Void)?
    @TaskLocal static var differentProfileJoinObserverForTesting: (@Sendable () -> Void)?

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

    static func withUserInitiatedBackgroundJoinObserverForTesting<T>(
        _ observer: (@Sendable () -> Void)?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$userInitiatedBackgroundJoinObserverForTesting.withValue(observer) {
            try await operation()
        }
    }

    static func withDifferentProfileJoinObserverForTesting<T>(
        _ observer: (@Sendable () -> Void)?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$differentProfileJoinObserverForTesting.withValue(observer) {
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
        state.loadedCooldownProfiles.removeAll()
        state.cooldownByProfile.removeAll()
        state.inFlightAttemptID = nil
        state.inFlightInteraction = nil
        state.inFlightProfileIdentifier = nil
        state.inFlightTask = nil
        state.nextAttemptID = 0
        state.lock.unlock()
        guard state.persistsCooldown else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: self.cooldownDefaultsKey)
        defaults.removeObject(forKey: self.cooldownIntervalDefaultsKey)
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(self.cooldownDefaultsKey + self.cooldownProfileKeySeparator)
            || key.hasPrefix(self.cooldownIntervalDefaultsKey + self.cooldownProfileKeySeparator)
        {
            defaults.removeObject(forKey: key)
        }
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
