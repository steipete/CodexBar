import CodexBarCore

protocol KimiTokenStoring: Sendable {
    func loadToken() throws -> String?
    func storeToken(_ token: String?) throws
}

struct KeychainKimiTokenStore: KimiTokenStoring {
    private let store = KeychainStringStore(
        account: "kimi-auth-token",
        promptKind: .kimiToken,
        logCategory: LogCategories.provider(.kimi, scope: "token-store"))

    func loadToken() throws -> String? {
        try self.store.load()
    }

    func storeToken(_ token: String?) throws {
        try self.store.store(token)
    }
}
