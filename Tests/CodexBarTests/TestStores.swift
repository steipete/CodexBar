import CodexBarCore
import Foundation
@testable import CodexBar

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
