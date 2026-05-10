import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct CodexBarConfigMigratorTests {
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

        _ = CodexBarConfigMigrator.loadOrMigrate(configStore: configStore, userDefaults: defaults, stores: stores)

        let firstSecretLoads = secrets.loadCount
        let firstAccountLoads = accountStore.loadCount
        #expect(firstSecretLoads > 0)
        #expect(firstAccountLoads == 1)
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey) == true)

        _ = CodexBarConfigMigrator.loadOrMigrate(configStore: configStore, userDefaults: defaults, stores: stores)

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

        _ = CodexBarConfigMigrator.loadOrMigrate(configStore: configStore, userDefaults: defaults, stores: stores)

        let firstSecretLoads = secrets.loadCount
        #expect(firstSecretLoads > 0)
        #expect(secrets.clearAttempts > 0)
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey) == false)

        secrets.throwOnStore = false
        _ = CodexBarConfigMigrator.loadOrMigrate(configStore: configStore, userDefaults: defaults, stores: stores)

        #expect(secrets.loadCount > firstSecretLoads)
        #expect(defaults.bool(forKey: Self.legacyMigrationCompletedKey) == true)
    }

    private static let legacyMigrationCompletedKey = "codexbar.legacySecretsMigrationCompleted"

    private static func legacyStores(
        secrets: CountingLegacySecretStore,
        accountStore: CountingTokenAccountStore) -> CodexBarConfigMigrator.LegacyStores
    {
        CodexBarConfigMigrator.LegacyStores(
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
            kimiK2TokenStore: secrets,
            augmentCookieStore: secrets,
            ampCookieStore: secrets,
            copilotTokenStore: secrets,
            tokenAccountStore: accountStore)
    }
}

private final class CountingLegacySecretStore: ZaiTokenStoring, SyntheticTokenStoring, CookieHeaderStoring,
    MiniMaxCookieStoring, MiniMaxAPITokenStoring, KimiTokenStoring, KimiK2TokenStoring, CopilotTokenStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var token: String?
    var throwOnStore: Bool
    private(set) var loadCount = 0
    private(set) var clearAttempts = 0

    init(token: String? = nil, throwOnStore: Bool = false) {
        self.token = token
        self.throwOnStore = throwOnStore
    }

    func loadToken() throws -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.loadCount += 1
        return self.token
    }

    func storeToken(_ token: String?) throws {
        try self.store(token)
    }

    func loadCookieHeader() throws -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.loadCount += 1
        return self.token
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
    private(set) var loadCount = 0

    func loadAccounts() throws -> [UsageProvider: ProviderTokenAccountData] {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.loadCount += 1
        return [:]
    }

    func storeAccounts(_: [UsageProvider: ProviderTokenAccountData]) throws {}

    func ensureFileExists() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-empty-accounts.json")
    }
}

private enum TestStoreError: Error {
    case storeFailed
}
