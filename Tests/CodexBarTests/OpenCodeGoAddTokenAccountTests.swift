import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct OpenCodeGoAddTokenAccountTests {
    @Test
    func `adding the first account migrates an existing single API key as Default`() {
        let settings = Self.makeSettings(suite: "OpenCodeGoAddTokenAccountTests-migrate")
        settings[providerConfig: .opencodego, field: .apiKey] = "sk-legacy"

        settings.addTokenAccount(provider: .opencodego, label: "Work", token: "sk-work")

        let accounts = settings.tokenAccounts(for: .opencodego)
        #expect(accounts.map(\.label) == ["Default", "Work"])
        #expect(accounts.map(\.token) == ["sk-legacy", "sk-work"])
        #expect(settings.providerConfig(for: .opencodego)?.apiKey == nil)
    }

    @Test
    func `adding an account with the same token as the existing key renames it instead of duplicating`() {
        let settings = Self.makeSettings(suite: "OpenCodeGoAddTokenAccountTests-rename")
        settings[providerConfig: .opencodego, field: .apiKey] = "sk-same"

        settings.addTokenAccount(provider: .opencodego, label: "Personal", token: "sk-same")

        let accounts = settings.tokenAccounts(for: .opencodego)
        #expect(accounts.count == 1)
        #expect(accounts[0].label == "Personal")
        #expect(accounts[0].token == "sk-same")
    }

    @Test
    func `migration is scoped to opencodego and does not apply to providers without the opt-in flag`() {
        let settings = Self.makeSettings(suite: "OpenCodeGoAddTokenAccountTests-scope")
        settings[providerConfig: .openrouter, field: .apiKey] = "decoy-token"

        settings.addTokenAccount(provider: .openrouter, label: "Personal", token: "test-key")

        let accounts = settings.tokenAccounts(for: .openrouter)
        #expect(accounts.count == 1)
        #expect(accounts[0].label == "Personal")
        #expect(!accounts.contains { $0.token == "decoy-token" })
    }

    private static func makeSettings(suite: String) -> SettingsStore {
        testSettingsStore(
            suiteName: "\(suite)-\(UUID().uuidString)",
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
