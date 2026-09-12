import CodexBarCore

protocol MiniMaxCookieStoring: Sendable {
    func loadCookieHeader() throws -> String?
    func storeCookieHeader(_ header: String?) throws
}

struct KeychainMiniMaxCookieStore: MiniMaxCookieStoring {
    private let store = KeychainStringStore(
        account: "minimax-cookie",
        promptKind: .minimaxCookie,
        logCategory: LogCategories.provider(.minimax, scope: "cookie-store"))

    func loadCookieHeader() throws -> String? {
        try self.store.load()
    }

    func storeCookieHeader(_ header: String?) throws {
        try self.store.store(header, isValid: { MiniMaxCookieHeader.normalized(from: $0) != nil })
    }
}
