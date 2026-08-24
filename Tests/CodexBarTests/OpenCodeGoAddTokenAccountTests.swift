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
    func `migration defaults on for every environment-injected provider, not just opencodego`() {
        let settings = Self.makeSettings(suite: "OpenCodeGoAddTokenAccountTests-scope")
        settings[providerConfig: .openrouter, field: .apiKey] = "or-existing"

        settings.addTokenAccount(provider: .openrouter, label: "Personal", token: "test-key")

        let accounts = settings.tokenAccounts(for: .openrouter)
        #expect(accounts.map(\.label) == ["Default", "Personal"])
        #expect(accounts.map(\.token) == ["or-existing", "test-key"])
        #expect(settings.providerConfig(for: .openrouter)?.apiKey == nil)
    }

    @Test
    func `a quoted legacy key is recognized as identical to the clean new token`() {
        let settings = Self.makeSettings(suite: "OpenCodeGoAddTokenAccountTests-quoted")
        // Simulates a key saved via the Settings UI, whose normalizer only trims whitespace and
        // does not strip wrapping quote characters.
        settings[providerConfig: .opencodego, field: .apiKey] = "\"sk-same\""

        settings.addTokenAccount(provider: .opencodego, label: "Personal", token: "sk-same")

        let accounts = settings.tokenAccounts(for: .opencodego)
        #expect(accounts.count == 1)
        #expect(accounts[0].label == "Personal")
        #expect(accounts[0].token == "sk-same")
    }

    private static func makeSettings(suite: String) -> SettingsStore {
        testSettingsStore(
            suiteName: "\(suite)-\(UUID().uuidString)",
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
