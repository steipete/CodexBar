import CodexBarCore
import Foundation

extension SettingsStore {
    private var codexPersistedActiveSource: CodexActiveSource {
        self.providerConfig(for: .codex)?.codexActiveSource ?? .liveSystem
    }

    private enum ManagedCodexAccountStoreState {
        case none
        case selected(ManagedCodexAccount)
        case unreadable
    }

    private static func failClosedManagedCodexHomePath(fileManager: FileManager = .default) -> String {
        ManagedCodexHomeFactory.defaultRootURL(fileManager: fileManager)
            .appendingPathComponent("managed-store-unreadable", isDirectory: true)
            .path
    }

    private func loadManagedCodexAccounts() throws -> ManagedCodexAccountSet {
        #if DEBUG
        if CodexManagedRemoteHomeTestingOverride.isUnreadable(for: self) {
            throw CodexManagedRemoteHomeTestingOverrideError.unreadableManagedStore
        }
        if let override = CodexManagedRemoteHomeTestingOverride.account(for: self) {
            return ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: [override])
        }
        let store = if let storeURL = CodexManagedRemoteHomeTestingOverride.managedStoreURL(for: self) {
            FileManagedCodexAccountStore(fileURL: storeURL)
        } else {
            FileManagedCodexAccountStore()
        }
        #else
        let store = FileManagedCodexAccountStore()
        #endif

        return try store.loadAccounts()
    }

    private func managedCodexAccountStoreState() -> ManagedCodexAccountStoreState {
        guard case let .managedAccount(id) = self.codexResolvedActiveSource else {
            return .none
        }
        do {
            let accounts = try self.loadManagedCodexAccounts()
            guard let account = accounts.account(id: id)
            else {
                return .none
            }
            return .selected(account)
        } catch {
            return .unreadable
        }
    }

    var activeManagedCodexAccount: ManagedCodexAccount? {
        guard case let .selected(account) = self.managedCodexAccountStoreState() else {
            return nil
        }
        return account
    }

    var activeManagedCodexRemoteHomePath: String? {
        guard case .managedAccount = self.codexResolvedActiveSource else {
            return nil
        }

        #if DEBUG
        if let override = CodexManagedRemoteHomeTestingOverride.homePath(for: self) {
            return override
        }
        #endif

        guard case let .managedAccount(id) = self.codexResolvedActiveSource else {
            return nil
        }

        do {
            let accounts = try self.loadManagedCodexAccounts()
            // A selected managed source must never fall back to ambient ~/.codex.
            return accounts.account(id: id)?.managedHomePath ?? Self.failClosedManagedCodexHomePath()
        } catch {
            return Self.failClosedManagedCodexHomePath()
        }
    }

    var activeManagedCodexCookieCacheScope: CookieHeaderCache.Scope? {
        switch self.managedCodexAccountStoreState() {
        case let .selected(account):
            .managedAccount(account.id)
        case .unreadable:
            .managedStoreUnreadable
        case .none:
            nil
        }
    }

    var hasUnreadableManagedCodexAccountStore: Bool {
        self.codexAccountReconciliationSnapshot.hasUnreadableAddedAccountStore
    }

    private var hasUnreadableSelectedManagedCodexAccountStore: Bool {
        guard case .managedAccount = self.codexResolvedActiveSource else {
            return false
        }
        if case .unreadable = self.managedCodexAccountStoreState() {
            return true
        }
        return false
    }

    private var hasUnavailableSelectedManagedCodexAccount: Bool {
        guard case let .managedAccount(id) = self.codexResolvedActiveSource else {
            return false
        }
        guard self.hasUnreadableManagedCodexAccountStore == false else {
            return false
        }
        do {
            let accounts = try self.loadManagedCodexAccounts()
            return accounts.account(id: id) == nil
        } catch {
            return false
        }
    }

    var codexUsageDataSource: CodexUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .codex)?.source
            return Self.codexUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .oauth: .oauth
            case .cli: .cli
            }
            self.updateProviderConfig(provider: .codex) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .codex, field: "usageSource", value: newValue.rawValue)
        }
    }

    var codexActiveSource: CodexActiveSource {
        get {
            self.codexPersistedActiveSource
        }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.codexActiveSource = newValue
            }
        }
    }

    var codexResolvedActiveSource: CodexActiveSource {
        self.codexResolvedActiveSourceState.resolvedSource
    }

    var codexResolvedActiveSourceState: CodexResolvedActiveSource {
        CodexActiveSourceResolver.resolve(from: self.codexAccountReconciliationSnapshot)
    }

    @discardableResult
    func persistResolvedCodexActiveSourceCorrectionIfNeeded() -> Bool {
        let resolution = self.codexResolvedActiveSourceState
        guard resolution.requiresPersistenceCorrection else { return false }
        self.codexActiveSource = resolution.resolvedSource
        return true
    }

    var codexCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .codex)?.sanitizedCookieHeader ?? "" }
        set {
            // This is intentionally provider-scoped today. A per-managed-account manual cookie override would need
            // its own storage and UI semantics so editing one account's header does not silently rewrite another's.
            self.updateProviderConfig(provider: .codex) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .codex, field: "cookieHeader", value: newValue)
        }
    }

    var codexCookieSource: ProviderCookieSource {
        get {
            let resolved = self.resolvedCookieSource(provider: .codex, fallback: .auto)
            return self.openAIWebAccessEnabled ? resolved : .off
        }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .codex, field: "cookieSource", value: newValue.rawValue)
            self.openAIWebAccessEnabled = newValue.isEnabled
        }
    }

    func ensureCodexCookieLoaded() {}
}

extension SettingsStore {
    var codexAccountReconciliationSnapshot: CodexAccountReconciliationSnapshot {
        self.codexAccountReconciler().loadSnapshot(environment: self.codexReconciliationEnvironment())
    }

    var codexVisibleAccountProjection: CodexVisibleAccountProjection {
        CodexVisibleAccountProjection.make(from: self.codexAccountReconciliationSnapshot)
    }

    var codexVisibleAccounts: [CodexVisibleAccount] {
        self.codexVisibleAccountProjection.visibleAccounts
    }

    @discardableResult
    func selectCodexVisibleAccount(id: String) -> Bool {
        guard let source = self.codexSource(forVisibleAccountID: id) else { return false }
        self.codexActiveSource = source
        return true
    }

    func selectAuthenticatedManagedCodexAccount(_ account: ManagedCodexAccount) {
        let visibleAccountID = Self.codexVisibleAccountID(for: account.email)
        if self.selectCodexVisibleAccount(id: visibleAccountID) {
            return
        }

        self.codexActiveSource = .managedAccount(id: account.id)
        _ = self.persistResolvedCodexActiveSourceCorrectionIfNeeded()
    }

    func codexSource(forVisibleAccountID id: String) -> CodexActiveSource? {
        self.codexVisibleAccountProjection.source(forVisibleAccountID: id)
    }

    private func codexAccountReconciler() -> DefaultCodexAccountReconciler {
        #if DEBUG
        let liveSystemAccountOverride = CodexManagedRemoteHomeTestingOverride.liveSystemAccount(for: self)
        let reconciliationEnvironmentOverride = CodexManagedRemoteHomeTestingOverride
            .reconciliationEnvironment(for: self)
        let managedAccountOverride = CodexManagedRemoteHomeTestingOverride.account(for: self)
        let managedStoreURLOverride = CodexManagedRemoteHomeTestingOverride.managedStoreURL(for: self)
        let unreadableStoreOverride = CodexManagedRemoteHomeTestingOverride.isUnreadable(for: self)
        guard CodexManagedRemoteHomeTestingOverride.hasAnyOverride(for: self) else {
            return DefaultCodexAccountReconciler(activeSource: self.codexPersistedActiveSource)
        }

        let storeLoader: @Sendable () throws -> ManagedCodexAccountSet
        if unreadableStoreOverride {
            storeLoader = { throw CodexManagedRemoteHomeTestingOverrideError.unreadableManagedStore }
        } else if let managedAccountOverride {
            let accounts = ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: [managedAccountOverride])
            storeLoader = { accounts }
        } else if let managedStoreURLOverride {
            let store = FileManagedCodexAccountStore(fileURL: managedStoreURLOverride)
            storeLoader = { try store.loadAccounts() }
        } else {
            let accounts = ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: [])
            storeLoader = { accounts }
        }

        return DefaultCodexAccountReconciler(
            storeLoader: storeLoader,
            systemObserver: CodexManagedRemoteHomeTestingSystemObserver(
                overrideAccount: liveSystemAccountOverride,
                usesInjectedEnvironment: reconciliationEnvironmentOverride != nil),
            activeSource: self.codexPersistedActiveSource)
        #else
        return DefaultCodexAccountReconciler(activeSource: self.codexPersistedActiveSource)
        #endif
    }

    private func codexReconciliationEnvironment() -> [String: String] {
        #if DEBUG
        if let override = CodexManagedRemoteHomeTestingOverride.reconciliationEnvironment(for: self) {
            return override
        }
        #endif
        return ProcessInfo.processInfo.environment
    }

    private static func codexVisibleAccountID(for email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

#if DEBUG
private enum CodexManagedRemoteHomeTestingOverride {
    private struct Override {
        var account: ManagedCodexAccount?
        var homePath: String?
        var unreadableStore: Bool = false
        var managedStoreURL: URL?
        var liveSystemAccount: ObservedSystemCodexAccount?
        var reconciliationEnvironment: [String: String]?

        var isEmpty: Bool {
            self.account == nil && self.homePath == nil && self.unreadableStore == false && self
                .managedStoreURL == nil && self.liveSystemAccount == nil && self
                .reconciliationEnvironment == nil
        }
    }

    @MainActor
    private static var values: [ObjectIdentifier: Override] = [:]

    @MainActor
    private static func store(_ override: Override, for key: ObjectIdentifier) {
        if override.isEmpty {
            self.values.removeValue(forKey: key)
        } else {
            self.values[key] = override
        }
    }

    @MainActor
    static func account(for settings: SettingsStore) -> ManagedCodexAccount? {
        self.values[ObjectIdentifier(settings)]?.account
    }

    @MainActor
    static func setAccount(_ account: ManagedCodexAccount?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.account = account
        self.store(override, for: key)
    }

    @MainActor
    static func homePath(for settings: SettingsStore) -> String? {
        self.values[ObjectIdentifier(settings)]?.homePath
    }

    @MainActor
    static func setHomePath(_ value: String?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.homePath = value
        self.store(override, for: key)
    }

    @MainActor
    static func isUnreadable(for settings: SettingsStore) -> Bool {
        self.values[ObjectIdentifier(settings)]?.unreadableStore == true
    }

    @MainActor
    static func setUnreadable(_ value: Bool, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.unreadableStore = value
        self.store(override, for: key)
    }

    @MainActor
    static func liveSystemAccount(for settings: SettingsStore) -> ObservedSystemCodexAccount? {
        self.values[ObjectIdentifier(settings)]?.liveSystemAccount
    }

    @MainActor
    static func managedStoreURL(for settings: SettingsStore) -> URL? {
        self.values[ObjectIdentifier(settings)]?.managedStoreURL
    }

    @MainActor
    static func setManagedStoreURL(_ value: URL?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.managedStoreURL = value
        self.store(override, for: key)
    }

    @MainActor
    static func setLiveSystemAccount(_ account: ObservedSystemCodexAccount?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.liveSystemAccount = account
        self.store(override, for: key)
    }

    @MainActor
    static func reconciliationEnvironment(for settings: SettingsStore) -> [String: String]? {
        self.values[ObjectIdentifier(settings)]?.reconciliationEnvironment
    }

    @MainActor
    static func setReconciliationEnvironment(_ environment: [String: String]?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.reconciliationEnvironment = environment
        self.store(override, for: key)
    }

    @MainActor
    static func hasAnyOverride(for settings: SettingsStore) -> Bool {
        self.values[ObjectIdentifier(settings)]?.isEmpty == false
    }
}

private enum CodexManagedRemoteHomeTestingOverrideError: Error {
    case unreadableManagedStore
}

private struct CodexManagedRemoteHomeTestingSystemObserver: CodexSystemAccountObserving {
    let overrideAccount: ObservedSystemCodexAccount?
    let usesInjectedEnvironment: Bool

    func loadSystemAccount(environment: [String: String]) throws -> ObservedSystemCodexAccount? {
        if let overrideAccount {
            return overrideAccount
        }
        guard self.usesInjectedEnvironment else {
            return nil
        }
        return try DefaultCodexSystemAccountObserver().loadSystemAccount(environment: environment)
    }
}

extension SettingsStore {
    var _test_activeManagedCodexRemoteHomePath: String? {
        get { CodexManagedRemoteHomeTestingOverride.homePath(for: self) }
        set { CodexManagedRemoteHomeTestingOverride.setHomePath(newValue, for: self) }
    }

    var _test_activeManagedCodexAccount: ManagedCodexAccount? {
        get { CodexManagedRemoteHomeTestingOverride.account(for: self) }
        set { CodexManagedRemoteHomeTestingOverride.setAccount(newValue, for: self) }
    }

    var _test_unreadableManagedCodexAccountStore: Bool {
        get { CodexManagedRemoteHomeTestingOverride.isUnreadable(for: self) }
        set { CodexManagedRemoteHomeTestingOverride.setUnreadable(newValue, for: self) }
    }

    var _test_managedCodexAccountStoreURL: URL? {
        get { CodexManagedRemoteHomeTestingOverride.managedStoreURL(for: self) }
        set { CodexManagedRemoteHomeTestingOverride.setManagedStoreURL(newValue, for: self) }
    }

    var _test_liveSystemCodexAccount: ObservedSystemCodexAccount? {
        get { CodexManagedRemoteHomeTestingOverride.liveSystemAccount(for: self) }
        set { CodexManagedRemoteHomeTestingOverride.setLiveSystemAccount(newValue, for: self) }
    }

    var _test_codexReconciliationEnvironment: [String: String]? {
        get { CodexManagedRemoteHomeTestingOverride.reconciliationEnvironment(for: self) }
        set { CodexManagedRemoteHomeTestingOverride.setReconciliationEnvironment(newValue, for: self) }
    }
}
#endif

extension SettingsStore {
    func codexSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.CodexProviderSettings {
        ProviderSettingsSnapshot.CodexProviderSettings(
            usageDataSource: self.codexUsageDataSource,
            cookieSource: self.codexSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.codexSnapshotCookieHeader(tokenOverride: tokenOverride),
            managedAccountStoreUnreadable: self.hasUnreadableSelectedManagedCodexAccountStore,
            managedAccountTargetUnavailable: self.hasUnavailableSelectedManagedCodexAccount)
    }

    private static func codexUsageDataSource(from source: ProviderSourceMode?) -> CodexUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .web, .api:
            return .auto
        case .cli:
            return .cli
        case .oauth:
            return .oauth
        }
    }

    private func codexSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.codexCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .codex),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .codex,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func codexSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.codexCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .codex),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .codex).isEmpty { return fallback }
        return .manual
    }
}
