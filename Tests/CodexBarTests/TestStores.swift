import CodexBarCore
import Foundation
@testable import CodexBar
#if os(macOS)
import AppKit
#endif

/// No Foundation search-domain fallback or persistent writes, including for absent keys.
final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]

    init(values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: "InMemoryUserDefaults-\(UUID().uuidString)")!
    }

    override func object(forKey defaultName: String) -> Any? {
        self.lock.withLock { self.values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        self.lock.withLock { self.values[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        self.set(nil as Any?, forKey: defaultName)
    }

    override func bool(forKey defaultName: String) -> Bool {
        (self.object(forKey: defaultName) as? NSNumber)?.boolValue ?? false
    }

    override func integer(forKey defaultName: String) -> Int {
        (self.object(forKey: defaultName) as? NSNumber)?.intValue ?? 0
    }

    override func float(forKey defaultName: String) -> Float {
        (self.object(forKey: defaultName) as? NSNumber)?.floatValue ?? 0
    }

    override func double(forKey defaultName: String) -> Double {
        (self.object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0
    }

    override func string(forKey defaultName: String) -> String? {
        self.object(forKey: defaultName) as? String
    }

    override func array(forKey defaultName: String) -> [Any]? {
        self.object(forKey: defaultName) as? [Any]
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        self.object(forKey: defaultName) as? [String: Any]
    }

    override func data(forKey defaultName: String) -> Data? {
        self.object(forKey: defaultName) as? Data
    }

    override func stringArray(forKey defaultName: String) -> [String]? {
        self.object(forKey: defaultName) as? [String]
    }

    override func url(forKey defaultName: String) -> URL? {
        self.object(forKey: defaultName) as? URL
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override func set(_ value: Int, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override func set(_ value: Float, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override func set(_ value: Double, forKey defaultName: String) {
        self.set(value as Any, forKey: defaultName)
    }

    override func set(_ url: URL?, forKey defaultName: String) {
        self.set(url as Any?, forKey: defaultName)
    }

    override func dictionaryRepresentation() -> [String: Any] {
        self.lock.withLock { self.values }
    }
}

final class InMemoryCookieHeaderStore: CookieHeaderStoring, @unchecked Sendable {
    var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func loadCookieHeader() throws -> String? {
        self.value
    }

    func storeCookieHeader(_ header: String?) throws {
        self.value = header
    }
}

final class InMemoryMiniMaxCookieStore: MiniMaxCookieStoring, @unchecked Sendable {
    var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func loadCookieHeader() throws -> String? {
        self.value
    }

    func storeCookieHeader(_ header: String?) throws {
        self.value = header
    }
}

final class InMemoryMiniMaxAPITokenStore: MiniMaxAPITokenStoring, @unchecked Sendable {
    var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func loadToken() throws -> String? {
        self.value
    }

    func storeToken(_ token: String?) throws {
        self.value = token
    }
}

final class InMemoryKimiTokenStore: KimiTokenStoring, @unchecked Sendable {
    var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func loadToken() throws -> String? {
        self.value
    }

    func storeToken(_ token: String?) throws {
        self.value = token
    }
}

final class InMemoryCopilotTokenStore: CopilotTokenStoring, @unchecked Sendable {
    var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func loadToken() throws -> String? {
        self.value
    }

    func storeToken(_ token: String?) throws {
        self.value = token
    }
}

final class InMemoryTokenAccountStore: ProviderTokenAccountStoring, @unchecked Sendable {
    var accounts: [UsageProvider: ProviderTokenAccountData] = [:]
    private let fileURL: URL

    init(fileURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "token-accounts-\(UUID().uuidString).json"))
    {
        self.fileURL = fileURL
    }

    func loadAccounts() throws -> [UsageProvider: ProviderTokenAccountData] {
        self.accounts
    }

    func storeAccounts(_ accounts: [UsageProvider: ProviderTokenAccountData]) throws {
        self.accounts = accounts
    }

    func ensureFileExists() throws -> URL {
        self.fileURL
    }
}

func testConfigStore(suiteName: String, reset: Bool = true) -> CodexBarConfigStore {
    let sanitized = suiteName.replacingOccurrences(of: "/", with: "-")
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexbar-tests", isDirectory: true)
        .appendingPathComponent(sanitized, isDirectory: true)
    let url = base.appendingPathComponent("config.json")
    if reset {
        try? FileManager.default.removeItem(at: url)
    }
    return CodexBarConfigStore(fileURL: url)
}

@MainActor
func testConfigWithAllProvidersDisabled() -> CodexBarConfig {
    let metadata = ProviderRegistry.shared.metadata
    var config = CodexBarConfig.makeDefault(metadata: metadata)
    for index in config.providers.indices {
        guard let provider = config.providers[index].id.firstPartyProvider,
              metadata[provider] != nil else { continue }
        config.providers[index].enabled = false
    }
    return config
}

@MainActor
func testSettingsStore(
    suiteName: String,
    tokenAccountStore: any ProviderTokenAccountStoring = InMemoryTokenAccountStore(),
    config: CodexBarConfig? = nil,
    prepareDefaults: ((UserDefaults) -> Void)? = nil) -> SettingsStore
{
    let isolatedSuiteName = "\(suiteName)-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: isolatedSuiteName) else {
        preconditionFailure("Could not create test defaults suite")
    }
    defaults.removePersistentDomain(forName: isolatedSuiteName)
    prepareDefaults?(defaults)
    let configStore = testConfigStore(suiteName: isolatedSuiteName)
    if let config {
        do {
            try configStore.save(config)
        } catch {
            preconditionFailure("Could not save test config: \(error)")
        }
    }
    return SettingsStore(
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
        tokenAccountStore: tokenAccountStore)
}

#if os(macOS)
@MainActor
func testStatusBar() -> NSStatusBar {
    // Standalone NSStatusBar instances can crash during swiftpm-testing-helper teardown.
    .system
}

@MainActor
@discardableResult
func withStatusItemControllerForTesting<T>(
    store: UsageStore,
    settings: SettingsStore,
    fetcher: UsageFetcher,
    account: AccountInfo? = nil,
    statusBar: NSStatusBar = .system,
    operation: (StatusItemController) throws -> T) rethrows -> T
{
    let controller = StatusItemController(
        store: store,
        settings: settings,
        account: account ?? AccountInfo(email: nil, plan: nil),
        updater: DisabledUpdaterController(),
        preferencesSelection: PreferencesSelection(),
        statusBar: statusBar)
    defer { controller.releaseStatusItemsForTesting() }
    return try operation(controller)
}

@MainActor
@discardableResult
func withStatusItemControllerForTesting<T>(
    store: UsageStore,
    settings: SettingsStore,
    fetcher: UsageFetcher,
    account: AccountInfo? = nil,
    statusBar: NSStatusBar = .system,
    operation: (StatusItemController) async throws -> T) async rethrows -> T
{
    let controller = StatusItemController(
        store: store,
        settings: settings,
        account: account ?? AccountInfo(email: nil, plan: nil),
        updater: DisabledUpdaterController(),
        preferencesSelection: PreferencesSelection(),
        statusBar: statusBar)
    defer { controller.releaseStatusItemsForTesting() }
    return try await operation(controller)
}
#endif

func testPlanUtilizationHistoryStore(suiteName: String, reset: Bool = true) -> PlanUtilizationHistoryStore {
    let sanitized = suiteName.replacingOccurrences(of: "/", with: "-")
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexbar-tests", isDirectory: true)
        .appendingPathComponent(sanitized, isDirectory: true)
    let url = base.appendingPathComponent("history", isDirectory: true)
    if reset {
        try? FileManager.default.removeItem(at: url)
    }
    return PlanUtilizationHistoryStore(directoryURL: url)
}
