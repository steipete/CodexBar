@testable import CodexBar

struct NoopKimiK2TokenStore: KimiK2TokenStoring {
    func loadToken() throws -> String? {
        nil
    }

    func storeToken(_: String?) throws {}
}
