@testable import CodexBar

struct NoopKimiTokenStore: KimiTokenStoring {
    func loadToken() throws -> String? { nil }
    func storeToken(_: String?) throws {}
}
