import CodexBarCore

protocol SyntheticTokenStoring: Sendable {
    func loadToken() throws -> String?
    func storeToken(_ token: String?) throws
}

struct KeychainSyntheticTokenStore: SyntheticTokenStoring {
    private let store = KeychainStringStore(
        account: "synthetic-api-key",
        promptKind: .syntheticToken,
        logCategory: LogCategories.provider(.synthetic, scope: "token-store"))

    func loadToken() throws -> String? {
        try self.store.load()
    }

    func storeToken(_ token: String?) throws {
        try self.store.store(token)
    }
}
