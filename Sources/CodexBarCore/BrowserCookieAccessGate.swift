import Foundation

#if os(macOS)
import os.lock
import SweetCookieKit

enum BrowserCookieStoreAccessDecision: Equatable {
    case allowed
    case suppressed
}

struct BrowserCookieStoreAccessSuppressedError: LocalizedError {
    var errorDescription: String? {
        "Browser cookie store access is suppressed for this process."
    }
}

public enum BrowserCookieAccessGate {
    private struct State {
        var loaded = false
        var deniedUntilBySource: [String: Date] = [:]
        var chromiumFamilyDeniedUntil: Date?

        var latestBrowserDenial: Date? {
            self.deniedUntilBySource
                .filter { !$0.key.hasPrefix(BrowserCookieAccessGate.credentialKeyPrefix) }
                .values.max()
        }
    }

    private final class ExplicitRetryScope: @unchecked Sendable {
        let bypassingCooldown: Bool
        private let cookieReadClaimed = OSAllocatedUnfairLock(initialState: false)

        init(bypassingCooldown: Bool) {
            self.bypassingCooldown = bypassingCooldown
        }

        func claimCookieRead() -> Bool {
            self.cookieReadClaimed.withLock { claimed in
                guard !claimed else { return false }
                claimed = true
                return true
            }
        }
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let defaultsKey = "browserCookieAccessDeniedUntil"
    private static let chromiumFamilyDefaultsKey = "__chromiumFamily__"
    private static let credentialKeyPrefix = "credential:"
    private static let cooldownInterval: TimeInterval = 60 * 60 * 6
    private static let log = CodexBarLog.logger(LogCategories.browserCookieGate)
    @TaskLocal private static var explicitRetryScope: ExplicitRetryScope?
    @TaskLocal private static var accessFailureObserver: (@Sendable (Browser, Bool) -> Void)?
    @TaskLocal private static var deniedBrowsersForTesting: [Browser]?
    #if DEBUG
    @TaskLocal private static var shouldAttemptOverrideForTesting: Bool?
    @TaskLocal private static var stateForTesting: OSAllocatedUnfairLock<State>?
    #endif

    private static var stateLock: OSAllocatedUnfairLock<State> {
        #if DEBUG
        if let stateForTesting { return stateForTesting }
        #endif
        return self.lock
    }

    static let allowTestCookieAccessEnvironmentKey = "CODEXBAR_ALLOW_TEST_BROWSER_COOKIE_ACCESS"

    public static func requiresKeychainPromptAcknowledgement(for browsers: [Browser]) -> Bool {
        browsers.contains(where: \.usesKeychainForCookieDecryption)
    }

    static func cookieStoreAccessDecision(
        homeDirectories: [URL],
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> BrowserCookieStoreAccessDecision
    {
        guard KeychainTestSafety.isRunningUnderTests(processName: processName, environment: environment),
              environment[self.allowTestCookieAccessEnvironmentKey] != "1"
        else {
            return .allowed
        }

        let defaultHomes = Set(BrowserCookieClient.defaultHomeDirectories().map(Self.normalizedPath))
        let usesDefaultHome = homeDirectories.contains { defaultHomes.contains(Self.normalizedPath($0)) }
        return usesDefaultHome ? .suppressed : .allowed
    }

    public static func shouldAttempt(_ browser: Browser, now: Date = Date()) -> Bool {
        let allowed = self.shouldAttemptWithPolicy(browser, now: now)
        if !allowed { self.recordAccessFailure(for: browser) }
        return allowed
    }

    static func withAccessFailureObserver<T>(
        _ observer: @escaping @Sendable (Browser, Bool) -> Void,
        operation: () throws -> T) rethrows -> T
    {
        try self.$accessFailureObserver.withValue(observer, operation: operation)
    }

    static func recordAccessFailure(for browser: Browser, profileDenied: Bool = false) {
        self.accessFailureObserver?(browser, profileDenied)
    }

    private static func shouldAttemptWithPolicy(_ browser: Browser, now: Date) -> Bool {
        #if DEBUG
        if let shouldAttemptOverrideForTesting {
            return shouldAttemptOverrideForTesting
        }
        #endif
        guard browser.usesKeychainForCookieDecryption else { return true }
        guard !KeychainAccessGate.isDisabled else { return false }
        guard ProviderInteractionContext.current == .userInitiated else {
            return self.shouldAttemptInBackground(browser)
        }
        if self.deniedBrowsersForTesting?.contains(browser) == true {
            return self.explicitRetryScope != nil
        }
        let shouldCheckKeychain = self.stateLock.withLock { state in
            self.loadIfNeeded(&state)
            if let blockedUntil = state.deniedUntilBySource[browser.rawValue] {
                if blockedUntil > now {
                    if self.explicitRetryScope?.bypassingCooldown == true { return true }
                    self.log.debug(
                        "Cookie access blocked",
                        metadata: ["browser": browser.displayName, "until": "\(blockedUntil.timeIntervalSince1970)"])
                    return false
                }
                state.deniedUntilBySource.removeValue(forKey: browser.rawValue)
                self.persist(state)
            }
            if let blockedUntil = state.chromiumFamilyDeniedUntil {
                if blockedUntil > now {
                    if self.explicitRetryScope?.bypassingCooldown == true { return true }
                    self.log.debug(
                        "Chromium-family cookie access blocked",
                        metadata: ["browser": browser.displayName, "until": "\(blockedUntil.timeIntervalSince1970)"])
                    return false
                }
                state.chromiumFamilyDeniedUntil = nil
                self.persist(state)
            }
            return true
        }
        guard shouldCheckKeychain else { return false }
        // Allow Once can leave a reusable cached key even when the ACL still requires interaction.
        if self.explicitRetryScope != nil { return true }

        let requiresInteraction = self.chromiumKeychainPreflight(for: browser).requiresInteraction
        if requiresInteraction {
            self.log.info(
                "Cookie access requires keychain interaction; skipping browser",
                metadata: ["browser": browser.displayName])
            return false
        }
        self.log.debug("Cookie access allowed", metadata: ["browser": browser.displayName])
        return true
    }

    public static func withExplicitRetry<T>(
        bypassingCooldown: Bool = false,
        _ operation: () throws -> T) rethrows -> T
    {
        let scope = self.explicitRetryScope ?? ExplicitRetryScope(bypassingCooldown: bypassingCooldown)
        return try self.$explicitRetryScope.withValue(scope) {
            try operation()
        }
    }

    public static func withExplicitRetry<T>(
        bypassingCooldown: Bool = false,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        let scope = self.explicitRetryScope ?? ExplicitRetryScope(bypassingCooldown: bypassingCooldown)
        return try await self.$explicitRetryScope.withValue(scope) {
            try await operation()
        }
    }

    static func withDeniedBrowsersForTesting<T>(
        _ browsers: [Browser],
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$deniedBrowsersForTesting.withValue(browsers) {
            try await operation()
        }
    }

    #if DEBUG
    static func withShouldAttemptOverrideForTesting<T>(
        _ result: Bool?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$shouldAttemptOverrideForTesting.withValue(result) {
            try operation()
        }
    }
    #endif

    static func operationPreservingAccessContext<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T) -> @Sendable () throws -> T
    {
        let preserved = self.operationPreservingAccessContext { (_: Void) in try operation() }
        return { try preserved(()) }
    }

    static func operationPreservingAccessContext<Input: Sendable, Output: Sendable>(
        _ operation: @escaping @Sendable (Input) throws -> Output) -> @Sendable (Input) throws -> Output
    {
        let interaction = ProviderInteractionContext.current
        let retryScope = self.explicitRetryScope
        let lockWitness = KeychainLockWitness.current
        return { input in
            try ProviderInteractionContext.$current.withValue(interaction) {
                try self.$explicitRetryScope.withValue(retryScope) {
                    try KeychainLockWitness.$current.withValue(lockWitness) {
                        try operation(input)
                    }
                }
            }
        }
    }

    static func withRecordReadInteractionPolicy<T>(_ operation: () throws -> T) rethrows -> T {
        do {
            return try BrowserCookieKeychainAccessGate.withUserInteractionDisallowed(operation)
        } catch {
            // ACL metadata is not a secret read. Spend the action's shared allowance only after
            // the actual no-UI read fails; SweetCookieKit caches a successful key across profiles.
            guard let cookieError = error as? BrowserCookieError,
                  case let .accessDenied(browser, _) = cookieError,
                  browser.usesKeychainForCookieDecryption,
                  !BrowserCookieKeychainAccessGate.isUserInteractionDisallowed,
                  self.shouldAttempt(browser),
                  ProviderInteractionContext.current == .userInitiated,
                  self.explicitRetryScope?.claimCookieRead() == true
            else { throw error }
            do {
                return try operation()
            } catch {
                self.recordIfNeeded(error, afterInteractiveRetry: true)
                throw error
            }
        }
    }

    /// CLI-owned credentials share the manual action's allowance with browser Safe Storage reads.
    static func claimCredentialRead(service: String, now: Date = Date()) -> Bool {
        guard !KeychainAccessGate.isDisabled,
              !BrowserCookieKeychainAccessGate.isUserInteractionDisallowed,
              ProviderInteractionContext.current == .userInitiated,
              let scope = self.explicitRetryScope
        else { return false }
        let deniedUntil = self.stateLock.withLock { state in
            self.loadIfNeeded(&state)
            return state.deniedUntilBySource[self.credentialKeyPrefix + service]
        }
        return (deniedUntil.map { $0 <= now } ?? true) && scope.claimCookieRead()
    }

    static func recordCredentialDenial(service: String, now: Date = Date()) {
        let blockedUntil = now.addingTimeInterval(self.cooldownInterval)
        self.stateLock.withLock { state in
            self.loadIfNeeded(&state)
            state.deniedUntilBySource[self.credentialKeyPrefix + service] = blockedUntil
            self.persist(state)
        }
    }

    #if DEBUG
    static func withIsolatedStateForTesting<T>(_ operation: () throws -> T) rethrows -> T {
        try self.$stateForTesting.withValue(
            self.stateForTesting ?? OSAllocatedUnfairLock(initialState: State(loaded: true)), operation: operation)
    }
    #endif

    public static func recordIfNeeded(_ error: Error, now: Date = Date(), afterInteractiveRetry: Bool = false) {
        guard let error = error as? BrowserCookieError else { return }
        guard case .accessDenied = error else { return }
        self.recordAccessFailure(for: error.browser)
        // A sibling can share a spent allowance without having made an interactive read.
        if afterInteractiveRetry {
            self.recordDenied(for: error.browser, now: now)
        }
    }

    public static func recordDenied(for browser: Browser, now: Date = Date()) {
        guard browser.usesKeychainForCookieDecryption else { return }
        let blockedUntil = now.addingTimeInterval(self.cooldownInterval)
        self.stateLock.withLock { state in
            self.loadIfNeeded(&state)
            state.deniedUntilBySource[browser.rawValue] = blockedUntil
            state.chromiumFamilyDeniedUntil = blockedUntil
            self.persist(state)
        }
        self.log
            .info(
                "Browser cookie access denied; suppressing Chromium family",
                metadata: [
                    "browser": browser.displayName,
                    "until": "\(blockedUntil.timeIntervalSince1970)",
                ])
    }

    public static func hasActiveDenial(for browser: Browser, now: Date = Date()) -> Bool {
        guard browser.usesKeychainForCookieDecryption else { return false }
        return self.stateLock.withLock { state in
            self.loadIfNeeded(&state)
            guard let blockedUntil = state.deniedUntilBySource[browser.rawValue] else { return false }
            guard blockedUntil <= now else { return true }
            state.deniedUntilBySource.removeValue(forKey: browser.rawValue)
            state.chromiumFamilyDeniedUntil = state.latestBrowserDenial
            self.persist(state)
            return false
        }
    }

    static func recordAllowed(for browser: Browser) {
        guard browser.usesKeychainForCookieDecryption,
              ProviderInteractionContext.current == .userInitiated,
              self.explicitRetryScope?.bypassingCooldown == true
        else { return }
        let clearedCooldown = self.stateLock.withLock { state in
            self.loadIfNeeded(&state)
            guard state.deniedUntilBySource[browser.rawValue] != nil,
                  state.chromiumFamilyDeniedUntil != nil
            else { return false }
            state.deniedUntilBySource.removeValue(forKey: browser.rawValue)
            state.chromiumFamilyDeniedUntil = state.latestBrowserDenial
            self.persist(state)
            return true
        }
        guard clearedCooldown else { return }
        self.log.info(
            "Explicit browser cookie retry succeeded",
            metadata: ["browser": browser.displayName])
    }

    public static func resetForTesting() {
        self.stateLock.withLock { state in
            state.loaded = true
            state.deniedUntilBySource.removeAll()
            state.chromiumFamilyDeniedUntil = nil
            #if DEBUG
            guard self.stateForTesting == nil else { return }
            #endif
            UserDefaults.standard.removeObject(forKey: self.defaultsKey)
        }
    }

    private static func chromiumKeychainPreflight(for browser: Browser) -> KeychainAccessPreflight.Outcome {
        let labels = browser.safeStorageLabels.isEmpty ? Browser.safeStorageLabels : browser.safeStorageLabels
        for label in labels {
            let outcome = KeychainAccessPreflight.checkGenericPassword(service: label.service, account: label.account)
            switch outcome {
            case .allowed, .interactionRequired, .temporarilyUnavailable:
                return outcome
            case .notFound, .failure:
                continue
            }
        }
        return .notFound
    }

    /// Background (non-user-initiated) refreshes must never surface a Keychain prompt. Rather than
    /// skipping unconditionally, reuse the strictly no-UI Safe Storage preflight: when the ACL already
    /// grants access (an explicit `.allowed`), a scheduled refresh can read cookies without any prompt,
    /// so background usage stays in sync instead of only updating when the menu is opened. Anything else
    /// — interaction required, not found, or a query failure — keeps the no-surprise boundary and skips.
    /// A current grant can recover background refresh without clearing the user-initiated denial cooldown.
    private static func shouldAttemptInBackground(_ browser: Browser) -> Bool {
        if self.deniedBrowsersForTesting?.contains(browser) == true {
            return false
        }
        guard self.chromiumKeychainPreflight(for: browser) == .allowed else {
            self.log.info(
                "Skipping background Chromium cookie import to avoid a Keychain prompt",
                metadata: ["browser": browser.displayName])
            return false
        }
        self.log.debug(
            "Background Chromium cookie import allowed by no-UI Keychain preflight",
            metadata: ["browser": browser.displayName])
        return true
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        guard let raw = UserDefaults.standard.dictionary(forKey: self.defaultsKey) as? [String: Double] else {
            return
        }
        state.chromiumFamilyDeniedUntil = raw[self.chromiumFamilyDefaultsKey].map(Date.init(timeIntervalSince1970:))
        state.deniedUntilBySource = raw
            .filter { $0.key != self.chromiumFamilyDefaultsKey }
            .mapValues { Date(timeIntervalSince1970: $0) }
        if state.chromiumFamilyDeniedUntil == nil {
            // Existing per-browser cooldowns become family-wide on upgrade.
            state.chromiumFamilyDeniedUntil = state.latestBrowserDenial
        }
    }

    private static func persist(_ state: State) {
        #if DEBUG
        guard self.stateForTesting == nil else { return }
        #endif
        var raw = state.deniedUntilBySource.mapValues { $0.timeIntervalSince1970 }
        raw[self.chromiumFamilyDefaultsKey] = state.chromiumFamilyDeniedUntil?.timeIntervalSince1970
        UserDefaults.standard.set(raw, forKey: self.defaultsKey)
    }
}

extension BrowserCookieClient {
    /// Discover store metadata without reading credentials; record reads enforce the browser access gate.
    public func codexBarStores(for browser: Browser) throws -> [BrowserCookieStore] {
        guard BrowserCookieAccessGate.cookieStoreAccessDecision(
            homeDirectories: self.configuration.homeDirectories) == .allowed
        else {
            throw BrowserCookieStoreAccessSuppressedError()
        }
        return self.stores(for: browser)
    }

    public func codexBarRecords(
        matching query: BrowserCookieQuery,
        in browser: Browser,
        logger: ((String) -> Void)? = nil) throws -> [BrowserCookieStoreRecords]
    {
        try self.readCookieRecords(for: browser) {
            try self.records(matching: query, in: browser, logger: logger)
        }
    }

    /// Read one selected store while preserving the same background and retry gates as browser-wide reads.
    /// Callers must resolve `store` from `codexBarStores(for:)` and must not fall back to another profile.
    public func codexBarRecords(
        matching query: BrowserCookieQuery,
        in store: BrowserCookieStore,
        logger: ((String) -> Void)? = nil) throws -> [BrowserCookieRecord]
    {
        try self.readCookieRecords(for: store.browser) {
            try self.records(matching: query, in: store, logger: logger)
        }
    }

    private func readCookieRecords<Record>(
        for browser: Browser,
        operation: () throws -> [Record]) throws -> [Record]
    {
        guard BrowserCookieAccessGate.cookieStoreAccessDecision(
            homeDirectories: self.configuration.homeDirectories) == .allowed
        else {
            throw BrowserCookieStoreAccessSuppressedError()
        }
        guard BrowserCookieAccessGate.shouldAttempt(browser) else { return [] }
        do {
            let records = try BrowserCookieAccessGate.withRecordReadInteractionPolicy(operation)
            BrowserCookieAccessGate.recordAllowed(for: browser)
            return records
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            throw error
        }
    }
}
#else
public enum BrowserCookieAccessGate {
    public static func requiresKeychainPromptAcknowledgement(for browsers: [Browser]) -> Bool {
        false
    }

    public static func shouldAttempt(_ browser: Browser, now: Date = Date()) -> Bool {
        true
    }

    public static func withExplicitRetry<T>(
        bypassingCooldown: Bool = false,
        _ operation: () throws -> T) rethrows -> T
    {
        try operation()
    }

    public static func withExplicitRetry<T>(
        bypassingCooldown: Bool = false,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await operation()
    }

    static func withDeniedBrowsersForTesting<T>(
        _: [Browser],
        isolation _: isolated (any Actor)? = #isolation,
        operation: () async throws -> T) async rethrows -> T
    {
        try await operation()
    }

    public static func recordIfNeeded(_ error: Error, now: Date = Date(), afterInteractiveRetry: Bool = false) {}
    public static func recordDenied(for browser: Browser, now: Date = Date()) {}
    public static func hasActiveDenial(for browser: Browser, now: Date = Date()) -> Bool {
        false
    }

    public static func resetForTesting() {}
}
#endif
