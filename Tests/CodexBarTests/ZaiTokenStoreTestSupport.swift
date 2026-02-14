@testable import CodexBar

struct NoopZaiTokenStore: ZaiTokenStoring {
    func loadToken() throws -> String? {
        nil
    }

    func storeToken(_: String?) throws {}
}

struct NoopSyntheticTokenStore: SyntheticTokenStoring {
    func loadToken() throws -> String? {
        nil
    }

    func storeToken(_: String?) throws {}
}
