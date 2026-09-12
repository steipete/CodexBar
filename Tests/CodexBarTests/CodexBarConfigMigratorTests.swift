import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct CodexBarConfigMigratorTests {
    @Test(arguments: [false, true])
    @MainActor
    func `settings applies stored keychain policy before legacy migration`(disabled: Bool) throws {
        let suite = "CodexBarConfigMigratorTests-keychain-startup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(disabled, forKey: "debugDisableKeychainAccess")

        let previousOverride = KeychainAccessGate.currentOverrideForTesting
        defer {
            if let previousOverride {
                KeychainAccessGate.isDisabled = previousOverride
            } else {
                KeychainAccessGate.resetOverrideForTesting()
            }
        }
        KeychainAccessGate.isDisabled = !disabled
        let secrets = CountingLegacySecretStore()
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: secrets,
            syntheticTokenStore: secrets,
            codexCookieStore: secrets,
            claudeCookieStore: secrets,
            cursorCookieStore: secrets,
            opencodeCookieStore: secrets,
            factoryCookieStore: secrets,
            minimaxCookieStore: secrets,
            minimaxAPITokenStore: secrets,
            kimiTokenStore: secrets,
            augmentCookieStore: secrets,
            ampCookieStore: secrets,
            copilotTokenStore: secrets,
            tokenAccountStore: CountingTokenAccountStore(),
            performInitialProviderDetection: false)

        #expect(store.debugDisableKeychainAccess == disabled)
        #expect(!secrets.keychainAccessOverridesAtLoad.isEmpty)
        #expect(secrets.keychainAccessOverridesAtLoad.allSatisfy { $0 == disabled })
    }

    @Test
    func `legacy Moonshot key is bound to its selected region`() throws {
        let suite = "CodexBarConfigMigratorTests-moonshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let configStore = testConfigStore(suiteName: suite)
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(
            id: .moonshot,
            apiKey: "legacy-china-token",
            region: MoonshotRegion.china.rawValue))
        try configStore.save(config)

        let migrated = CodexBarConfigMigrator.loadOrMigrate(
            configStore: configStore,
            userDefaults: defaults,
            keychainAccessDisabled: false,
            stores: Self.legacyStores(
                secrets: CountingLegacySecretStore(),
                accountStore: CountingTokenAccountStore()))

        #expect(migrated.providerConfig(for: .moonshot)?.apiKeyRegion == MoonshotRegion.china.rawValue)
        #expect(try configStore.load()?.providerConfig(for: .moonshot)?.apiKeyRegion == MoonshotRegion.china.rawValue)
    }

    @Test
    func `legacy secret migration completion flag skips repeated scans`() throws {
        let suite = "CodexBarConfigMigratorTests-skip-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let secrets = CountingLegacySecretStore()
        let accountStore = CountingTokenAccountStore()
        let stores = Self.legacyStores(secrets: secrets, accountStore: accountStore)
        let configStore = testConfigStore(suiteName: suite)

        _ = Self.migrate(configStore: configStore, defaults: defaults, stores: stores)

        let firstSecretLoads = secrets.loadCount
        let firstAccountLoads = accountStore.loadCount
        #expect(firstSecretLoads > 0)
        #expect(firstAccountLoads == 1)
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey) == true)

        _ = Self.migrate(configStore: configStore, defaults: defaults, stores: stores)

        #expect(secrets.loadCount == firstSecretLoads)
        #expect(accountStore.loadCount == firstAccountLoads)
    }

    @Test
    func `legacy migration completion waits for successful cleanup`() throws {
        let suite = "CodexBarConfigMigratorTests-cleanup-failure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let secrets = CountingLegacySecretStore(token: "legacy-token", throwOnStore: true)
        let accountStore = CountingTokenAccountStore()
        let stores = Self.legacyStores(secrets: secrets, accountStore: accountStore)
        let configStore = testConfigStore(suiteName: suite)

        _ = Self.migrate(configStore: configStore, defaults: defaults, stores: stores)

        let firstSecretLoads = secrets.loadCount
        #expect(firstSecretLoads > 0)
        #expect(secrets.clearAttempts > 0)
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey) == false)

        secrets.throwOnStore = false
        _ = Self.migrate(configStore: configStore, defaults: defaults, stores: stores)

        #expect(secrets.loadCount > firstSecretLoads)
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey) == true)
    }

    @Test
    func `legacy stores are kept when migrated config save fails`() throws {
        let suite = "CodexBarConfigMigratorTests-save-failure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tests", isDirectory: true)
            .appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let blockedDirectory = base.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedDirectory)

        let secrets = CountingLegacySecretStore(token: "legacy-token")
        let accountStore = CountingTokenAccountStore()
        let stores = Self.legacyStores(secrets: secrets, accountStore: accountStore)
        let configStore = CodexBarConfigStore(
            fileURL: blockedDirectory.appendingPathComponent("config.json"))

        _ = Self.migrate(configStore: configStore, defaults: defaults, stores: stores)

        #expect(secrets.clearAttempts == 0)
        #expect(try secrets.loadToken() == "legacy-token")
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey) == false)

        try FileManager.default.removeItem(at: blockedDirectory)
        _ = Self.migrate(configStore: configStore, defaults: defaults, stores: stores)

        #expect(secrets.clearAttempts > 0)
        #expect(try secrets.loadToken() == nil)
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey) == true)
    }

    @Test
    func `all legacy load failures defer cleanup and retry on the next launch`() throws {
        let suite = "CodexBarConfigMigratorTests-load-failure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let secrets = CountingLegacySecretStore(throwOnLoad: true)
        let accountStore = CountingTokenAccountStore(throwOnLoad: true)
        let stores = Self.legacyStores(secrets: secrets, accountStore: accountStore)
        let configStore = testConfigStore(suiteName: suite)

        _ = CodexBarConfigMigrator.loadOrMigrate(
            configStore: configStore,
            userDefaults: defaults,
            keychainAccessDisabled: false,
            stores: stores)

        let failedSecretLoads = secrets.loadCount
        let failedAccountLoads = accountStore.loadCount
        #expect(failedSecretLoads > 0)
        #expect(failedAccountLoads == 1)
        #expect(secrets.clearAttempts == 0)
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey) == false)

        secrets.throwOnLoad = false
        accountStore.throwOnLoad = false
        _ = CodexBarConfigMigrator.loadOrMigrate(
            configStore: configStore,
            userDefaults: defaults,
            keychainAccessDisabled: false,
            stores: stores)

        #expect(secrets.loadCount > failedSecretLoads)
        #expect(accountStore.loadCount > failedAccountLoads)
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey))
    }

    @Test
    func `mixed legacy load results persist successes without clearing until retry succeeds`() throws {
        let suite = "CodexBarConfigMigratorTests-mixed-load-failure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let readableSecrets = CountingLegacySecretStore(token: "legacy-token")
        let unreadableSecrets = CountingLegacySecretStore(throwOnLoad: true)
        let accountStore = CountingTokenAccountStore()
        let stores = Self.legacyStores(
            secrets: readableSecrets,
            accountStore: accountStore,
            syntheticTokenStore: unreadableSecrets)
        let configStore = testConfigStore(suiteName: suite)

        let first = CodexBarConfigMigrator.loadOrMigrate(
            configStore: configStore,
            userDefaults: defaults,
            keychainAccessDisabled: false,
            stores: stores)

        #expect(first.providerConfig(for: .zai)?.apiKey == "legacy-token")
        #expect(try configStore.load()?.providerConfig(for: .zai)?.apiKey == "legacy-token")
        #expect(readableSecrets.clearAttempts == 0)
        #expect(unreadableSecrets.clearAttempts == 0)
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey) == false)

        let firstUnreadableLoadCount = unreadableSecrets.loadCount
        unreadableSecrets.throwOnLoad = false
        _ = CodexBarConfigMigrator.loadOrMigrate(
            configStore: configStore,
            userDefaults: defaults,
            keychainAccessDisabled: false,
            stores: stores)

        #expect(unreadableSecrets.loadCount > firstUnreadableLoadCount)
        #expect(readableSecrets.clearAttempts > 0)
        #expect(unreadableSecrets.clearAttempts > 0)
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey))
    }

    private static let legacyMigrationCompletedKey = "codexbar.legacySecretsMigrationCompleted"

    @Test(arguments: [false, true])
    func `disabled keychain migration preserves sources and retries after access returns`(
        hidesToken: Bool) throws
    {
        let suite = "CodexBarConfigMigratorTests-deferred-keychain-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("fixture-cookie=manual", forKey: "kimiManualCookieHeader")
        let configStore = testConfigStore(suiteName: suite)
        let secrets = CountingLegacySecretStore(token: "legacy-fixture-token")
        secrets.hideTokenOnLoad = hidesToken
        let stores = Self.legacyStores(secrets: secrets, accountStore: CountingTokenAccountStore())

        let deferred = CodexBarConfigMigrator.loadOrMigrate(
            configStore: configStore,
            userDefaults: defaults,
            keychainAccessDisabled: true,
            stores: stores)

        #expect(deferred.providerConfig(for: .kimi)?.cookieHeader != nil)
        #expect(try configStore.load()?.providerConfig(for: .kimi)?.cookieHeader != nil)
        #expect(!defaults.bool(forKey: Self.legacyMigrationCompletedKey))
        #expect(secrets.clearAttempts == 0)

        secrets.hideTokenOnLoad = false
        let recovered = Self.migrate(configStore: configStore, defaults: defaults, stores: stores)

        #expect(recovered.providerConfig(for: .zai)?.apiKey == "legacy-fixture-token")
        #expect(try configStore.load()?.providerConfig(for: .zai)?.apiKey == "legacy-fixture-token")
        #expect(secrets.clearAttempts > 0)
        #expect(try secrets.loadToken() == nil)
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey))
    }

    private static func migrate(
        configStore: CodexBarConfigStore,
        defaults: UserDefaults,
        stores: CodexBarConfigMigrator.LegacyStores) -> CodexBarConfig
    {
        CodexBarConfigMigrator.loadOrMigrate(
            configStore: configStore,
            userDefaults: defaults,
            keychainAccessDisabled: false,
            stores: stores)
    }

    private static func legacyStores(
        secrets: CountingLegacySecretStore,
        accountStore: CountingTokenAccountStore,
        syntheticTokenStore: CountingLegacySecretStore? = nil) -> CodexBarConfigMigrator.LegacyStores
    {
        CodexBarConfigMigrator.LegacyStores(
            zaiTokenStore: secrets,
            syntheticTokenStore: syntheticTokenStore ?? secrets,
            codexCookieStore: secrets,
            claudeCookieStore: secrets,
            cursorCookieStore: secrets,
            opencodeCookieStore: secrets,
            factoryCookieStore: secrets,
            minimaxCookieStore: secrets,
            minimaxAPITokenStore: secrets,
            kimiTokenStore: secrets,
            augmentCookieStore: secrets,
            ampCookieStore: secrets,
            copilotTokenStore: secrets,
            tokenAccountStore: accountStore)
    }
}

private final class CountingLegacySecretStore: ZaiTokenStoring, SyntheticTokenStoring, CookieHeaderStoring,
    MiniMaxCookieStoring, MiniMaxAPITokenStoring, KimiTokenStoring, CopilotTokenStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var token: String?
    var throwOnLoad: Bool
    var throwOnStore: Bool
    var hideTokenOnLoad = false
    private(set) var loadCount = 0
    private(set) var clearAttempts = 0
    private(set) var keychainAccessOverridesAtLoad: [Bool?] = []

    init(token: String? = nil, throwOnLoad: Bool = false, throwOnStore: Bool = false) {
        self.token = token
        self.throwOnLoad = throwOnLoad
        self.throwOnStore = throwOnStore
    }

    func loadToken() throws -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.loadCount += 1
        self.keychainAccessOverridesAtLoad.append(KeychainAccessGate.currentOverrideForTesting)
        if self.throwOnLoad {
            throw TestStoreError.loadFailed
        }
        return self.hideTokenOnLoad ? nil : self.token
    }

    func storeToken(_ token: String?) throws {
        try self.store(token)
    }

    func loadCookieHeader() throws -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.loadCount += 1
        self.keychainAccessOverridesAtLoad.append(KeychainAccessGate.currentOverrideForTesting)
        if self.throwOnLoad {
            throw TestStoreError.loadFailed
        }
        return self.hideTokenOnLoad ? nil : self.token
    }

    func storeCookieHeader(_ header: String?) throws {
        try self.store(header)
    }

    private func store(_ value: String?) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.clearAttempts += value == nil ? 1 : 0
        if self.throwOnStore {
            throw TestStoreError.storeFailed
        }
        self.token = value
    }
}

private final class CountingTokenAccountStore: ProviderTokenAccountStoring, @unchecked Sendable {
    private let lock = NSLock()
    var throwOnLoad: Bool
    private(set) var loadCount = 0

    init(throwOnLoad: Bool = false) {
        self.throwOnLoad = throwOnLoad
    }

    func loadAccounts() throws -> [UsageProvider: ProviderTokenAccountData] {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.loadCount += 1
        if self.throwOnLoad {
            throw TestStoreError.loadFailed
        }
        return [:]
    }

    func storeAccounts(_: [UsageProvider: ProviderTokenAccountData]) throws {}

    func ensureFileExists() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-empty-accounts.json")
    }
}

private enum TestStoreError: Error {
    case loadFailed
    case storeFailed
}
