import CodexBarCore
import Foundation

extension SettingsStore {
    private var standardizedSelectedCodexProfilePath: String? {
        guard let selectedPath = self.selectedCodexProfilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedPath.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: selectedPath).standardizedFileURL.path
    }

    func codexProfiles() -> [DiscoveredCodexProfile] {
        #if DEBUG
        if let override = self._test_codexProfiles {
            return override
        }
        #endif
        _ = self.codexProfilesRevision
        return CodexProfileStore.displayProfiles()
    }

    func selectedCodexProfile() -> DiscoveredCodexProfile? {
        #if DEBUG
        if let override = self._test_codexProfiles {
            if let standardizedPath = self.standardizedSelectedCodexProfilePath {
                if let exact = override.first(where: { $0.fileURL.standardizedFileURL.path == standardizedPath }) {
                    return exact
                }
            }
            return override.first(where: \.isActiveInCodex)
        }
        #endif
        return CodexProfileStore.selectedDisplayProfile(selectedPath: self.selectedCodexProfilePath)
    }

    func selectCodexProfile(path: String?) {
        self.selectedCodexProfilePath = path
    }

    func reloadCodexProfiles() {
        self.codexProfilesRevision &+= 1
    }

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

    var hasUnavailableSelectedCodexProfile: Bool {
        guard case .liveSystem = self.codexResolvedActiveSource else {
            return false
        }
        guard let standardizedSelectedPath = self.standardizedSelectedCodexProfilePath else {
            return false
        }
        let defaultPath = CodexOAuthCredentialsStore.authFilePath().standardizedFileURL.path
        guard standardizedSelectedPath != defaultPath else { return false }
        return self.codexProfiles().contains(where: { $0.fileURL.standardizedFileURL.path == standardizedSelectedPath }) == false
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
        if let visibleAccountID = self.codexVisibleAccountProjection.visibleAccounts
            .first(where: { $0.storedAccountID == account.id })?
            .id,
            self.selectCodexVisibleAccount(id: visibleAccountID)
        {
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

    private final class Entry {
        weak var settings: SettingsStore?
        var overrideValue: Override

        init(settings: SettingsStore, overrideValue: Override) {
            self.settings = settings
            self.overrideValue = overrideValue
        }
    }

    @MainActor
    private static var values: [ObjectIdentifier: Entry] = [:]

    @MainActor
    private static func entry(for settings: SettingsStore) -> Entry? {
        let key = ObjectIdentifier(settings)
        guard let entry = self.values[key] else { return nil }
        guard let storedSettings = entry.settings, storedSettings === settings else {
            self.values.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    @MainActor
    static func account(for settings: SettingsStore) -> ManagedCodexAccount? {
        self.entry(for: settings)?.overrideValue.account
    }

    @MainActor
    static func setAccount(_ account: ManagedCodexAccount?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.entry(for: settings)?.overrideValue ?? Override()
        override.account = account
        if override.isEmpty {
            self.values.removeValue(forKey: key)
        } else {
            self.values[key] = Entry(settings: settings, overrideValue: override)
        }
    }

    @MainActor
    static func homePath(for settings: SettingsStore) -> String? {
        self.entry(for: settings)?.overrideValue.homePath
    }

    @MainActor
    static func setHomePath(_ value: String?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.entry(for: settings)?.overrideValue ?? Override()
        override.homePath = value
        if override.isEmpty {
            self.values.removeValue(forKey: key)
        } else {
            self.values[key] = Entry(settings: settings, overrideValue: override)
        }
    }

    @MainActor
    static func isUnreadable(for settings: SettingsStore) -> Bool {
        self.entry(for: settings)?.overrideValue.unreadableStore == true
    }

    @MainActor
    static func setUnreadable(_ value: Bool, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.entry(for: settings)?.overrideValue ?? Override()
        override.unreadableStore = value
        if override.isEmpty {
            self.values.removeValue(forKey: key)
        } else {
            self.values[key] = Entry(settings: settings, overrideValue: override)
        }
    }

    @MainActor
    static func liveSystemAccount(for settings: SettingsStore) -> ObservedSystemCodexAccount? {
        self.entry(for: settings)?.overrideValue.liveSystemAccount
    }

    @MainActor
    static func managedStoreURL(for settings: SettingsStore) -> URL? {
        self.entry(for: settings)?.overrideValue.managedStoreURL
    }

    @MainActor
    static func setManagedStoreURL(_ value: URL?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.entry(for: settings)?.overrideValue ?? Override()
        override.managedStoreURL = value
        if override.isEmpty {
            self.values.removeValue(forKey: key)
        } else {
            self.values[key] = Entry(settings: settings, overrideValue: override)
        }
    }

    @MainActor
    static func setLiveSystemAccount(_ account: ObservedSystemCodexAccount?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.entry(for: settings)?.overrideValue ?? Override()
        override.liveSystemAccount = account
        if override.isEmpty {
            self.values.removeValue(forKey: key)
        } else {
            self.values[key] = Entry(settings: settings, overrideValue: override)
        }
    }

    @MainActor
    static func reconciliationEnvironment(for settings: SettingsStore) -> [String: String]? {
        self.entry(for: settings)?.overrideValue.reconciliationEnvironment
    }

    @MainActor
    static func setReconciliationEnvironment(_ environment: [String: String]?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.entry(for: settings)?.overrideValue ?? Override()
        override.reconciliationEnvironment = environment
        if override.isEmpty {
            self.values.removeValue(forKey: key)
        } else {
            self.values[key] = Entry(settings: settings, overrideValue: override)
        }
    }

    @MainActor
    static func hasAnyOverride(for settings: SettingsStore) -> Bool {
        self.entry(for: settings)?.overrideValue.isEmpty == false
    }
}

private enum CodexManagedRemoteHomeTestingOverrideError: Error {
    case unreadableManagedStore
}

#if DEBUG
private enum CodexProfileTestingOverride {
    @MainActor private static var values: [ObjectIdentifier: [DiscoveredCodexProfile]] = [:]

    @MainActor
    static func profiles(for settings: SettingsStore) -> [DiscoveredCodexProfile]? {
        self.values[ObjectIdentifier(settings)]
    }

    @MainActor
    static func setProfiles(_ profiles: [DiscoveredCodexProfile]?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        if let profiles {
            self.values[key] = profiles
        } else {
            self.values.removeValue(forKey: key)
        }
    }
}
#endif

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
    var _test_codexProfiles: [DiscoveredCodexProfile]? {
        get { CodexProfileTestingOverride.profiles(for: self) }
        set { CodexProfileTestingOverride.setProfiles(newValue, for: self) }
    }

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
            managedAccountTargetUnavailable: self.hasUnavailableSelectedManagedCodexAccount,
            selectedProfileUnavailable: self.hasUnavailableSelectedCodexProfile)
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

    func codexEnvironmentOverrides(tokenOverride: TokenAccountOverride?) -> [String: String] {
        if let tokenOverride, tokenOverride.provider == .codex {
            let overrideURL = URL(fileURLWithPath: tokenOverride.account.token).standardizedFileURL
            return [CodexProfileExecutionEnvironment.authFileOverrideKey: overrideURL.path]
        }
        guard case .liveSystem = self.codexResolvedActiveSource else { return [:] }
        guard let selectedPath = self.standardizedSelectedCodexProfilePath else { return [:] }
        let defaultPath = CodexOAuthCredentialsStore.authFilePath().standardizedFileURL.path
        guard selectedPath != defaultPath else { return [:] }
        return [CodexProfileExecutionEnvironment.authFileOverrideKey: selectedPath]
    }

    func selectedCodexProfileEmail() -> String? {
        switch self.codexResolvedActiveSource {
        case .managedAccount:
            return self.activeManagedCodexAccount?.email
        case .liveSystem:
            if let standardizedSelectedPath = self.standardizedSelectedCodexProfilePath {
                if let overrideProfile = self.codexProfiles().first(where: {
                    $0.fileURL.standardizedFileURL.path == standardizedSelectedPath
                }) {
                    return overrideProfile.accountEmail
                }
                let overrideURL = URL(fileURLWithPath: standardizedSelectedPath)
                return CodexProfileStore.profile(
                    at: overrideURL,
                    alias: overrideURL.deletingPathExtension().lastPathComponent)?.accountEmail
            }
            return self.selectedCodexProfile()?.accountEmail
        }
    }

    func selectedCodexProfilePlan() -> String? {
        guard case .liveSystem = self.codexResolvedActiveSource else { return nil }
        guard let standardizedSelectedPath = self.standardizedSelectedCodexProfilePath else {
            return self.selectedCodexProfile()?.plan
        }
        if let overrideProfile = self.codexProfiles().first(where: {
            $0.fileURL.standardizedFileURL.path == standardizedSelectedPath
        }) {
            return overrideProfile.plan
        }
        let overrideURL = URL(fileURLWithPath: standardizedSelectedPath)
        return CodexProfileStore.profile(
            at: overrideURL,
            alias: overrideURL.deletingPathExtension().lastPathComponent)?.plan
    }

    func selectedCodexProfileAlias() -> String? {
        guard case .liveSystem = self.codexResolvedActiveSource else { return nil }
        guard let standardizedSelectedPath = self.standardizedSelectedCodexProfilePath else {
            return self.selectedCodexProfile()?.alias
        }
        if let overrideProfile = self.codexProfiles().first(where: {
            $0.fileURL.standardizedFileURL.path == standardizedSelectedPath
        }) {
            return overrideProfile.alias
        }
        let overrideURL = URL(fileURLWithPath: standardizedSelectedPath)
        return CodexProfileStore.profile(
            at: overrideURL,
            alias: overrideURL.deletingPathExtension().lastPathComponent)?.alias
    }

    func codexDiscoveredProfileSelection(for tokenOverride: TokenAccountOverride?) -> CodexProfileSelection? {
        if let tokenOverride, tokenOverride.provider == .codex {
            let overrideURL = URL(fileURLWithPath: tokenOverride.account.token)
            if let overrideProfile = self.codexProfiles().first(where: {
                $0.fileURL.standardizedFileURL == overrideURL.standardizedFileURL
            }) {
                return overrideProfile.selection
            }
            return CodexProfileStore.profile(
                at: overrideURL,
                alias: overrideURL.deletingPathExtension().lastPathComponent)?.selection
        }
        guard let standardizedSelectedPath = self.standardizedSelectedCodexProfilePath else {
            return self.selectedCodexProfile()?.selection
        }
        if let overrideProfile = self.codexProfiles().first(where: {
            $0.fileURL.standardizedFileURL.path == standardizedSelectedPath
        }) {
            return overrideProfile.selection
        }
        let overrideURL = URL(fileURLWithPath: standardizedSelectedPath)
        return CodexProfileStore.profile(
            at: overrideURL,
            alias: overrideURL.deletingPathExtension().lastPathComponent)?.selection
    }
}
