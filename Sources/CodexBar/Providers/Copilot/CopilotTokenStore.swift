import CodexBarCore

protocol CopilotTokenStoring: Sendable {
    func loadToken() throws -> String?
    func storeToken(_ token: String?) throws
}

struct KeychainCopilotTokenStore: CopilotTokenStoring {
    private let store = KeychainStringStore(
        account: "copilot-api-token",
        promptKind: .copilotToken,
        logCategory: LogCategories.provider(.copilot, scope: "token-store"))

    func loadToken() throws -> String? {
        try self.store.load()
    }

    func storeToken(_ token: String?) throws {
        try self.store.store(token)
    }
}
