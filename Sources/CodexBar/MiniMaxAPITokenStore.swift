import CodexBarCore

protocol MiniMaxAPITokenStoring: Sendable {
    func loadToken() throws -> String?
    func storeToken(_ token: String?) throws
}

struct KeychainMiniMaxAPITokenStore: MiniMaxAPITokenStoring {
    private let store = KeychainStringStore(
        account: "minimax-api-token",
        promptKind: .minimaxToken,
        logCategory: LogCategories.provider(.minimax, scope: "api-token-store"))

    func loadToken() throws -> String? {
        try self.store.load()
    }

    func storeToken(_ token: String?) throws {
        try self.store.store(token)
    }
}
