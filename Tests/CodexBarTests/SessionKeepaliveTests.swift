import CodexBarCore
import XCTest

final class KeepaliveConfigTests: XCTestCase {
    // MARK: - Mode Encoding/Decoding Tests

    func test_intervalModeEncodingDecoding() throws {
        let config = KeepaliveConfig(mode: .interval(1800), enabled: true)

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(KeepaliveConfig.self, from: data)

        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.enabled, true)

        if case .interval(let seconds) = decoded.mode {
            XCTAssertEqual(seconds, 1800)
        } else {
            XCTFail("Expected interval mode")
        }
    }

    func test_dailyModeEncodingDecoding() throws {
        let config = KeepaliveConfig(mode: .daily(hour: 9, minute: 30), enabled: true)

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(KeepaliveConfig.self, from: data)

        XCTAssertEqual(decoded, config)

        if case .daily(let hour, let minute) = decoded.mode {
            XCTAssertEqual(hour, 9)
            XCTAssertEqual(minute, 30)
        } else {
            XCTFail("Expected daily mode")
        }
    }

    func test_beforeExpiryModeEncodingDecoding() throws {
        let config = KeepaliveConfig(mode: .beforeExpiry(buffer: 300), enabled: true)

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(KeepaliveConfig.self, from: data)

        XCTAssertEqual(decoded, config)

        if case .beforeExpiry(let buffer) = decoded.mode {
            XCTAssertEqual(buffer, 300)
        } else {
            XCTFail("Expected beforeExpiry mode")
        }
    }

    // MARK: - Default Configuration Tests

    func test_augmentDefaultConfig() {
        let config = KeepaliveConfig.augmentDefault

        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.minRefreshInterval, 120)

        if case .beforeExpiry(let buffer) = config.mode {
            XCTAssertEqual(buffer, 300) // 5 minutes
        } else {
            XCTFail("Expected beforeExpiry mode for Augment")
        }
    }

    func test_claudeDefaultConfig() {
        let config = KeepaliveConfig.claudeDefault

        XCTAssertTrue(config.enabled)

        if case .interval(let seconds) = config.mode {
            XCTAssertEqual(seconds, 1800) // 30 minutes
        } else {
            XCTFail("Expected interval mode for Claude")
        }
    }

    func test_codexDefaultConfig() {
        let config = KeepaliveConfig.codexDefault

        XCTAssertTrue(config.enabled)

        if case .interval(let seconds) = config.mode {
            XCTAssertEqual(seconds, 3600) // 60 minutes
        } else {
            XCTFail("Expected interval mode for Codex")
        }
    }

    func test_disabledConfig() {
        let config = KeepaliveConfig.disabled

        XCTAssertFalse(config.enabled)
    }

    // MARK: - Description Tests

    func test_intervalModeDescription() {
        let config = KeepaliveConfig(mode: .interval(1800), enabled: true)
        let description = config.description

        XCTAssertTrue(description.contains("enabled"))
        XCTAssertTrue(description.contains("every 1800s"))
    }

    func test_dailyModeDescription() {
        let config = KeepaliveConfig(mode: .daily(hour: 9, minute: 30), enabled: true)
        let description = config.description

        XCTAssertTrue(description.contains("enabled"))
        XCTAssertTrue(description.contains("daily at 09:30"))
    }

    func test_beforeExpiryModeDescription() {
        let config = KeepaliveConfig(mode: .beforeExpiry(buffer: 300), enabled: true)
        let description = config.description

        XCTAssertTrue(description.contains("enabled"))
        XCTAssertTrue(description.contains("300s before expiry"))
    }

    func test_disabledConfigDescription() {
        let config = KeepaliveConfig.disabled
        let description = config.description

        XCTAssertTrue(description.contains("disabled"))
    }

    // MARK: - Custom Configuration Tests

    func test_customMinRefreshInterval() {
        let config = KeepaliveConfig(
            mode: .interval(1800),
            enabled: true,
            minRefreshInterval: 60)

        XCTAssertEqual(config.minRefreshInterval, 60)
    }

    func test_customMaxConsecutiveFailures() {
        let config = KeepaliveConfig(
            mode: .interval(1800),
            enabled: true,
            maxConsecutiveFailures: 10)

        XCTAssertEqual(config.maxConsecutiveFailures, 10)
    }
}

// MARK: - KeepaliveConfigStore Tests

final class KeepaliveConfigStoreTests: XCTestCase {
    var store: KeepaliveConfigStore!
    var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Use a test suite name to avoid polluting real UserDefaults
        self.testDefaults = UserDefaults(suiteName: "com.codexbar.tests.keepalive")!
        self.store = KeepaliveConfigStore(userDefaults: self.testDefaults)
    }

    override func tearDown() {
        // Clean up test data
        self.store.deleteAll()
        self.testDefaults.removePersistentDomain(forName: "com.codexbar.tests.keepalive")
        super.tearDown()
    }

    // MARK: - Save/Load Tests

    func test_saveAndLoadConfig() {
        let config = KeepaliveConfig.augmentDefault
        self.store.save(config, for: .augment)

        let loaded = self.store.load(for: .augment)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, config)
    }

    func test_loadNonexistentConfig() {
        let loaded = self.store.load(for: .claude)
        XCTAssertNil(loaded)
    }

    func test_loadOrDefaultWithSavedConfig() {
        let config = KeepaliveConfig.claudeDefault
        self.store.save(config, for: .claude)

        let loaded = self.store.loadOrDefault(for: .claude, default: .disabled)
        XCTAssertEqual(loaded, config)
    }

    func test_loadOrDefaultWithoutSavedConfig() {
        let defaultConfig = KeepaliveConfig.disabled
        let loaded = self.store.loadOrDefault(for: .codex, default: defaultConfig)
        XCTAssertEqual(loaded, defaultConfig)
    }

    // MARK: - Delete Tests

    func test_deleteConfig() {
        let config = KeepaliveConfig.augmentDefault
        self.store.save(config, for: .augment)

        XCTAssertNotNil(self.store.load(for: .augment))

        self.store.delete(for: .augment)
        XCTAssertNil(self.store.load(for: .augment))
    }

    // MARK: - Bulk Operations Tests

    func test_saveAndLoadAll() {
        let configs: [UsageProvider: KeepaliveConfig] = [
            .augment: .augmentDefault,
            .claude: .claudeDefault,
            .codex: .codexDefault,
        ]

        self.store.saveAll(configs)

        let loaded = self.store.loadAll()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded[.augment], .augmentDefault)
        XCTAssertEqual(loaded[.claude], .claudeDefault)
        XCTAssertEqual(loaded[.codex], .codexDefault)
    }

    func test_deleteAll() {
        let configs: [UsageProvider: KeepaliveConfig] = [
            .augment: .augmentDefault,
            .claude: .claudeDefault,
            .codex: .codexDefault,
        ]

        self.store.saveAll(configs)
        XCTAssertEqual(self.store.loadAll().count, 3)

        self.store.deleteAll()
        XCTAssertEqual(self.store.loadAll().count, 0)
    }

    // MARK: - Provider Defaults Tests

    func test_defaultConfigForAugment() {
        let config = KeepaliveConfigStore.defaultConfig(for: .augment)
        XCTAssertEqual(config, .augmentDefault)
    }

    func test_defaultConfigForClaude() {
        let config = KeepaliveConfigStore.defaultConfig(for: .claude)
        XCTAssertEqual(config, .claudeDefault)
    }

    func test_defaultConfigForCodex() {
        let config = KeepaliveConfigStore.defaultConfig(for: .codex)
        XCTAssertEqual(config, .codexDefault)
    }

    func test_defaultConfigForUnsupportedProvider() {
        let config = KeepaliveConfigStore.defaultConfig(for: .gemini)
        XCTAssertEqual(config, .disabled)
    }

    func test_loadWithProviderDefaults() {
        // No saved config - should return provider default
        let config = self.store.loadWithProviderDefaults(for: .augment)
        XCTAssertEqual(config, .augmentDefault)

        // Save custom config
        let customConfig = KeepaliveConfig(mode: .interval(900), enabled: true)
        self.store.save(customConfig, for: .augment)

        // Should return saved config, not default
        let loaded = self.store.loadWithProviderDefaults(for: .augment)
        XCTAssertEqual(loaded, customConfig)
    }
}

// MARK: - SessionKeepaliveManager Tests

@MainActor
final class SessionKeepaliveManagerTests: XCTestCase {
    var manager: SessionKeepaliveManager!

    override func setUp() async throws {
        try await super.setUp()
        self.manager = SessionKeepaliveManager.shared
    }

    override func tearDown() async throws {
        // Stop all keepalive tasks
        for provider in UsageProvider.allCases {
            self.manager.stop(provider: provider)
        }
        try await super.tearDown()
    }

    // MARK: - Start/Stop Tests

    func test_startKeepalive() async {
        let config = KeepaliveConfig.augmentDefault
        self.manager.start(provider: .augment, config: config)

        let loadedConfig = self.manager.configuration(for: .augment)
        XCTAssertNotNil(loadedConfig)
        XCTAssertEqual(loadedConfig, config)
    }

    func test_stopKeepalive() async {
        let config = KeepaliveConfig.augmentDefault
        self.manager.start(provider: .augment, config: config)

        XCTAssertNotNil(self.manager.configuration(for: .augment))

        self.manager.stop(provider: .augment)
        XCTAssertNil(self.manager.configuration(for: .augment))
    }

    func test_startWithDisabledConfig() async {
        let config = KeepaliveConfig.disabled
        self.manager.start(provider: .augment, config: config)

        // Should not start if config is disabled
        XCTAssertNil(self.manager.configuration(for: .augment))
    }

    // MARK: - Configuration Tests

    func test_configurationForNonStartedProvider() async {
        let config = self.manager.configuration(for: .claude)
        XCTAssertNil(config)
    }

    func test_lastRefreshTimeInitiallyNil() async {
        let time = self.manager.lastRefreshTime(for: .augment)
        XCTAssertNil(time)
    }
}

