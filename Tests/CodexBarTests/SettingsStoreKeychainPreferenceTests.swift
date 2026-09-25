import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct SettingsStoreKeychainPreferenceTests {
    @Test(arguments: [nil, false, true] as [Bool?], [nil, false, true] as [Bool?])
    func `local keychain preference wins and shared defaults fill only an absent value`(
        localValue: Bool?, sharedValue: Bool?)
    {
        let local = InMemoryUserDefaults()
        let shared = InMemoryUserDefaults()
        if let localValue {
            local.set(localValue, forKey: "debugDisableKeychainAccess")
        }
        if let sharedValue {
            shared.set(sharedValue, forKey: "debugDisableKeychainAccess")
        }

        let disabled = SettingsStore.loadDebugDisableKeychainAccess(userDefaults: local, sharedDefaults: shared)

        #expect(disabled == (localValue ?? sharedValue ?? false))
        #expect(local.object(forKey: "debugDisableKeychainAccess") as? Bool == (localValue ?? sharedValue))
        #expect(shared.object(forKey: "debugDisableKeychainAccess") as? Bool == sharedValue)
    }

    @Test
    func `ordinary tests never invoke the shared defaults resolver`() throws {
        try #require(SettingsStore.isRunningTests)
        var resolutions = 0
        let shared = SettingsStore.resolveSharedDefaults {
            resolutions += 1
            return InMemoryUserDefaults()
        }

        #expect(shared == nil)
        #expect(resolutions == 0)
        #expect(SettingsStore.sharedDefaults == nil)
        let local = InMemoryUserDefaults()
        #expect(!SettingsStore.shouldBridgeSharedDefaults(for: local))
        #expect(!SettingsStore.loadDebugDisableKeychainAccess(userDefaults: local))
        #expect(local.dictionaryRepresentation().isEmpty)
    }

    @Test(arguments: [false, true])
    func `settings initialization isolates app group migration and keychain policy`(disabled: Bool) throws {
        let local = InMemoryUserDefaults()
        local.set(disabled, forKey: "debugDisableKeychainAccess")
        var keychainAccessValues: [Bool] = []
        let keychainAccessPolicy = SettingsStoreKeychainAccessPolicy(
            setDisabled: { keychainAccessValues.append($0) },
            isExplicitlyDisabled: { keychainAccessValues.last ?? false })
        try self.withSettingsStore(
            defaults: local,
            keychainAccessPolicy: keychainAccessPolicy)
        { store in
            #expect(local.object(forKey: AppGroupSupport.migrationVersionKey) == nil)
            #expect(local.object(forKey: "widgetSelectedProvider") == nil)
            #expect(store.debugDisableKeychainAccess == disabled)
            #expect(store.refreshFrequency == .adaptive)
            // Config/secret migration remains independent of app-group migration.
            #expect(local.bool(forKey: "codexbar.legacySecretsMigrationCompleted") == !disabled)

            store.debugDisableKeychainAccess = !disabled
            #expect(local.bool(forKey: "debugDisableKeychainAccess") == !disabled)
            store.debugDisableKeychainAccess = disabled
            #expect(local.bool(forKey: "debugDisableKeychainAccess") == disabled)
            #expect(local.object(forKey: AppGroupSupport.migrationVersionKey) == nil)
            #expect(SettingsStore.sharedDefaults == nil)
            #expect(keychainAccessValues == [disabled, disabled, !disabled, disabled])
        }
    }

    @Test(arguments: ["providerDetectionCompleted", AppGroupSupport.migrationVersionKey])
    func `existing launch markers still keep the legacy refresh default`(marker: String) throws {
        let local = InMemoryUserDefaults()
        local.set(1, forKey: marker)
        try self.withSettingsStore(defaults: local) { store in
            #expect(store.refreshFrequency == .fiveMinutes)
            #expect(local.integer(forKey: marker) == 1)
            if marker != AppGroupSupport.migrationVersionKey {
                #expect(local.object(forKey: AppGroupSupport.migrationVersionKey) == nil)
            }
        }
    }

    @Test(arguments: ["openAIWebAccess", "openAIWebAccessEnabled"])
    func `explicit web denial migrates to the config used by CLI cookie refresh`(preferenceKey: String) throws {
        let defaults = InMemoryUserDefaults(values: [preferenceKey: false])
        try self.withSettingsStore(defaults: defaults) { store in
            #expect(!store.openAIWebAccessEnabled)
            #expect(store.codexCookieSource == .off)
            // The CLI reads config.json, not the app's UserDefaults consent flag.
            try store.configStore.save(store.configSnapshot)
            let config = try #require(try store.configStore.load())
            #expect(config.providerConfig(for: .codex)?.cookieSource == .off)
        }
    }

    @Test
    func `startup persists inferred denial before a later launch sees generic configuration`() {
        let first = InMemoryUserDefaults()
        #expect(!SettingsStore.initializeOpenAIWebAccessPreference(
            userDefaults: first, config: CodexBarConfig(providers: []), hadExistingConfig: false))
        #expect(first.object(forKey: "openAIWebAccessEnabled") as? Bool == false)
        let reloaded = InMemoryUserDefaults(values: first.dictionaryRepresentation())
        #expect(!SettingsStore.initializeOpenAIWebAccessPreference(
            userDefaults: reloaded,
            config: CodexBarConfig(providers: [ProviderConfig(id: .codex)]),
            hadExistingConfig: true))
    }

    @Test(arguments: ["false", "invalid"])
    func `malformed stored web preference stays denied instead of inferring new consent`(value: String) throws {
        let defaults = InMemoryUserDefaults(values: ["openAIWebAccessEnabled": value])
        let config = CodexBarConfig(providers: [ProviderConfig(id: .codex)])
        #expect(!SettingsStore.initializeOpenAIWebAccessPreference(
            userDefaults: defaults, config: config, hadExistingConfig: true))
        try self.withSettingsStore(defaults: defaults, config: config) { store in
            #expect(!store.openAIWebAccessEnabled)
            #expect(store.configSnapshot.providerConfig(for: .codex)?.cookieSource == .off)
        }
    }

    @Test(arguments: ["openAIWebAccess", "openAIWebAccessEnabled"])
    func `startup denial survives two launches and remains off in CLI configuration`(preferenceKey: String) throws {
        var values: [String: Any] = [preferenceKey: false]
        var savedConfig: CodexBarConfig?
        for _ in 0..<2 {
            let defaults = InMemoryUserDefaults(values: values)
            try self.withSettingsStore(defaults: defaults, config: savedConfig) { store in
                #expect(!store.openAIWebAccessEnabled)
                #expect(store.codexCookieSource == .off)
                savedConfig = try store.configStore.load()
                #expect(savedConfig?.providerConfig(for: .codex)?.cookieSource == .off)
                values = defaults.dictionaryRepresentation()
                #expect(values["openAIWebAccessEnabled"] as? Bool == false)
            }
        }
    }

    @Test
    func `first launch publishes disabled browser access to CLI configuration`() throws {
        try self.withSettingsStore(defaults: InMemoryUserDefaults()) { store in
            #expect(!store.openAIWebAccessEnabled)
            let saved = try store.configStore.load()
            #expect(saved?.providerConfig(for: .codex)?.cookieSource == .off)
        }
    }

    private func withSettingsStore(
        defaults: InMemoryUserDefaults,
        config: CodexBarConfig? = nil,
        keychainAccessPolicy: SettingsStoreKeychainAccessPolicy = SettingsStoreKeychainAccessPolicy(
            setDisabled: { _ in },
            isExplicitlyDisabled: { false }),
        operation: (SettingsStore) throws -> Void) throws
    {
        // Fail before constructing settings if the caller deliberately opted into live user state.
        try #require(SettingsStore.isRunningTests)
        try #require(KeychainTestSafety.resolveShouldBlockRealKeychainAccess(
            processName: ProcessInfo.processInfo.processName,
            environment: ProcessInfo.processInfo.environment))
        try #require(!KeychainAccessGate.isDisabledByEnvironment())
        try #require(KeychainAccessGate.processDisableReason == nil)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreKeychainPreferenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Could not remove synthetic settings fixture: \(error)")
            }
        }
        let configStore = CodexBarConfigStore(fileURL: root.appendingPathComponent("config.json"))
        if let config { try configStore.save(config) }
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(fileURL: root.appendingPathComponent("accounts.json")),
            antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore(
                fileURL: root.appendingPathComponent("antigravity.json")),
            keychainAccessPolicy: keychainAccessPolicy,
            performInitialProviderDetection: false)
        defer { store.configFileWatcher?.stop() }
        try operation(store)
    }
}
