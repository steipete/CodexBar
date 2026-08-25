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

    @Test
    func `a quoted incoming token is recognized as identical to the clean legacy key`() {
        let settings = Self.makeSettings(suite: "OpenCodeGoAddTokenAccountTests-quoted-incoming")
        // Reverse of the above: the stored legacy key is already clean, but the user pastes a
        // quoted copy of the same credential into Add Account.
        settings[providerConfig: .opencodego, field: .apiKey] = "sk-same"

        settings.addTokenAccount(provider: .opencodego, label: "Personal", token: "\"sk-same\"")

        let accounts = settings.tokenAccounts(for: .opencodego)
        #expect(accounts.count == 1)
        #expect(accounts[0].label == "Personal")
    }

    @Test
    func `adding an account migrates a stray legacy key even when accounts already exist`() {
        let settings = Self.makeSettings(suite: "OpenCodeGoAddTokenAccountTests-stray")
        settings.addTokenAccount(provider: .opencodego, label: "Acc1", token: "sk-acc1")
        settings.addTokenAccount(provider: .opencodego, label: "Acc2", token: "sk-acc2")

        // Simulates a provider-level key set through some other path (e.g. the CLI's plain
        // `set-api-key` with no --label) after accounts already existed - a reachable state
        // where the key sits unmigrated alongside a non-empty account list.
        settings[providerConfig: .opencodego, field: .apiKey] = "sk-stray"

        settings.addTokenAccount(provider: .opencodego, label: "Acc3", token: "sk-acc3")

        let accounts = settings.tokenAccounts(for: .opencodego)
        #expect(accounts.map(\.label) == ["Acc1", "Acc2", "Default", "Acc3"])
        #expect(accounts.map(\.token) == ["sk-acc1", "sk-acc2", "sk-stray", "sk-acc3"])
        #expect(settings.providerConfig(for: .opencodego)?.apiKey == nil)
    }

    @Test
    func `adding an account does not re-migrate a stray key already represented in accounts`() {
        let settings = Self.makeSettings(suite: "OpenCodeGoAddTokenAccountTests-already-represented")
        settings.addTokenAccount(provider: .opencodego, label: "Default", token: "sk-a")

        // Simulates a plain (unlabeled) set-api-key re-populating the provider-level field with
        // a token that is already represented by an existing account.
        settings[providerConfig: .opencodego, field: .apiKey] = "sk-a"

        settings.addTokenAccount(provider: .opencodego, label: "Work", token: "sk-b")

        let accounts = settings.tokenAccounts(for: .opencodego)
        #expect(accounts.map(\.label) == ["Default", "Work"])
        #expect(accounts.map(\.token) == ["sk-a", "sk-b"])
        #expect(settings.providerConfig(for: .opencodego)?.apiKey == nil)
    }

    private static func makeSettings(suite: String) -> SettingsStore {
        testSettingsStore(
            suiteName: "\(suite)-\(UUID().uuidString)",
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
