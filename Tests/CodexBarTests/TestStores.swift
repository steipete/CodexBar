import CodexBarCore
import Foundation
@testable import CodexBar
#if os(macOS)
import AppKit
#endif

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

final class InMemoryKimiK2TokenStore: KimiK2TokenStoring, @unchecked Sendable {
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

#if os(macOS)
@MainActor
@discardableResult
func withStatusItemControllerForTesting<T>(
    store: UsageStore,
    settings: SettingsStore,
    fetcher: UsageFetcher,
    statusBar: NSStatusBar = .system,
    operation: (StatusItemController) throws -> T) rethrows -> T
{
    let controller = StatusItemController(
        store: store,
        settings: settings,
        account: fetcher.loadAccountInfo(),
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
    statusBar: NSStatusBar = .system,
    operation: (StatusItemController) async throws -> T) async rethrows -> T
{
    let controller = StatusItemController(
        store: store,
        settings: settings,
        account: fetcher.loadAccountInfo(),
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
