import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct TokenAccountCLISelectionTests {
    @Test
    func `usage and cards share provider selection constraints`() {
        let all = TokenAccountCLISelection(label: nil, index: nil, allAccounts: true)
        #expect(all.providerSelectionError([.codex]) == nil)
        #expect(all.providerSelectionError([.claude]) == nil)
        #expect(all.providerSelectionError([.codex, .claude]) == "account selection requires a single provider.")
        #expect(all.providerSelectionError([]) == "account selection requires a single provider.")
        #expect(all.providerSelectionError([.jetbrains]) == "jetbrains does not support token accounts.")
        let automatic = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        #expect(automatic.providerSelectionError([.jetbrains, .claude]) == nil)
    }

    @Test
    func `antigravity CLI leaves saved OAuth accounts passive`() throws {
        let context = try Self.context(provider: .antigravity, source: .auto)
        #expect(try context.resolvedAccounts(for: .antigravity, sourceMode: .cli).isEmpty)
        let configuredCLI = try Self.context(provider: .antigravity, source: .cli)
        #expect(try configuredCLI.resolvedAccounts(for: .antigravity).isEmpty)
    }

    @Test
    func `antigravity explicit CLI rejects every saved account override`() throws {
        for selection in Self.accountOverrides {
            let context = try Self.context(provider: .antigravity, source: .auto, selection: selection)
            Self.expectCLIAccountConflict {
                try context.resolvedAccounts(for: .antigravity, sourceMode: .cli)
            }
        }
    }

    @Test
    func `antigravity configured CLI rejects every saved account override`() throws {
        for selection in Self.accountOverrides {
            let context = try Self.context(provider: .antigravity, source: .cli, selection: selection)
            Self.expectCLIAccountConflict {
                try context.resolvedAccounts(for: .antigravity)
            }
        }
    }

    @Test
    func `antigravity auto and OAuth retain saved account selection`() throws {
        let selections = Self.accountOverrides + [TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)]
        for source in [ProviderSourceMode.auto, .oauth] {
            for selection in selections {
                let context = try Self.context(provider: .antigravity, source: .cli, selection: selection)
                let accounts = try context.resolvedAccounts(for: .antigravity, sourceMode: source)
                #expect(accounts.map(\.label) == ["Primary"])
                let configured = try Self.context(provider: .antigravity, source: source, selection: selection)
                #expect(try configured.resolvedAccounts(for: .antigravity).map(\.label) == ["Primary"])
            }
        }
    }

    @Test
    func `other providers retain saved account overrides with CLI source`() throws {
        for selection in Self.accountOverrides {
            let context = try Self.context(provider: .claude, source: .cli, selection: selection)
            #expect(try context.resolvedAccounts(for: .claude).map(\.label) == ["Primary"])
        }
    }

    @Test
    func `cli token updater writes refreshed credential when stored token is unchanged`() async throws {
        let account = Self.account(token: "original-token")
        let config = Self.config(with: account)
        let store = try Self.configStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(config)
        let context = try Self.writebackContext(config: config, store: store)
        let updater = try #require(context.tokenUpdater(for: account))

        await updater(.antigravity, account.id, "refreshed-token")

        let stored = try Self.storedToken(store: store, accountID: account.id)
        #expect(stored == "refreshed-token")
    }

    @Test
    func `cli token updater drops writeback when stored credential changed mid run`() async throws {
        let account = Self.account(token: "original-token")
        let config = Self.config(with: account)
        let store = try Self.configStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(config)
        let context = try Self.writebackContext(config: config, store: store)
        let updater = try #require(context.tokenUpdater(for: account))

        // Another process reauthorized the account while the fetch was in flight.
        let reassigned = Self.account(id: account.id, token: "reauthorized-token")
        try store.save(Self.config(with: reassigned))

        await updater(.antigravity, account.id, "stale-refresh")

        let stored = try Self.storedToken(store: store, accountID: account.id)
        #expect(stored == "reauthorized-token")
    }

    @Test
    func `cli token updater accepts successive owned writes but rejects external reauthorization`() async throws {
        let account = Self.account(token: "original-token")
        let config = Self.config(with: account)
        let store = try Self.configStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(config)
        let context = try Self.writebackContext(config: config, store: store)
        let updater = try #require(context.tokenUpdater(for: account))

        // OAuth first refreshes the grant, then persists the discovered project on the same fetch.
        await updater(.antigravity, account.id, "refreshed-token")
        await updater(.antigravity, account.id, "refreshed-token-with-project")
        #expect(try Self.storedToken(store: store, accountID: account.id) == "refreshed-token-with-project")

        try store.save(Self.config(with: Self.account(id: account.id, token: "reauthorized-token")))
        await updater(.antigravity, account.id, "late-owned-update")
        #expect(try Self.storedToken(store: store, accountID: account.id) == "reauthorized-token")
    }

    @Test
    func `cli refresh cannot publish during another config writer transaction`() throws {
        let account = Self.account(token: "original-token")
        let store = try Self.configStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(Self.config(with: account))
        let reauthorized = Self.account(id: account.id, token: "reauthorized-token")
        // Pause the other writer at its final rename, after it has staged the new authorization.
        let beforePublish: @Sendable (URL) throws -> Void = { _ in
            try CredentialFileWriter.$beforePublishForTesting.withValue(nil) {
                try TokenAccountCLIContext.updateStoredTokenAccount(
                    store: store,
                    provider: .antigravity,
                    accountID: account.id,
                    expectedToken: account.token,
                    token: "stale-refresh")
                #expect(try Self.storedToken(store: store, accountID: account.id) == "original-token")
            }
        }
        try CredentialFileWriter.$beforePublishForTesting.withValue(beforePublish) {
            try store.save(Self.config(with: reauthorized))
        }
        #expect(try Self.storedToken(store: store, accountID: account.id) == "reauthorized-token")
    }

    private static var accountOverrides: [TokenAccountCLISelection] {
        [
            TokenAccountCLISelection(label: "Primary", index: nil, allAccounts: false),
            TokenAccountCLISelection(label: nil, index: 0, allAccounts: false),
            TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
        ]
    }

    private static func context(
        provider: UsageProvider,
        source: ProviderSourceMode,
        selection: TokenAccountCLISelection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false))
        throws -> TokenAccountCLIContext
    {
        let account = ProviderTokenAccount(
            id: UUID(), label: "Primary", token: "fixture-token", addedAt: 0, lastUsed: nil)
        let config = CodexBarConfig(providers: [ProviderConfig(
            id: provider.instanceID,
            source: source,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0))])
        return try TokenAccountCLIContext(
            selection: selection, config: config, verbose: false, baseEnvironment: [:])
    }

    private static func account(id: UUID = UUID(), token: String) -> ProviderTokenAccount {
        ProviderTokenAccount(id: id, label: "Primary", token: token, addedAt: 0, lastUsed: nil)
    }

    private static func config(with account: ProviderTokenAccount) -> CodexBarConfig {
        CodexBarConfig(providers: [ProviderConfig(
            id: UsageProvider.antigravity.instanceID,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0))])
    }

    private static func configStore() throws -> CodexBarConfigStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-account-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return CodexBarConfigStore(fileURL: directory.appendingPathComponent("config.json"))
    }

    private static func writebackContext(
        config: CodexBarConfig,
        store: CodexBarConfigStore) throws -> TokenAccountCLIContext
    {
        try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [:],
            configStore: store)
    }

    private static func storedToken(store: CodexBarConfigStore, accountID: UUID) throws -> String? {
        try store.load()?
            .providerConfig(for: UsageProvider.antigravity.instanceID)?
            .tokenAccounts?.accounts
            .first(where: { $0.id == accountID })?.token
    }

    private static func expectCLIAccountConflict(_ resolve: () throws -> [ProviderTokenAccount]) {
        do {
            _ = try resolve()
            Issue.record("Antigravity CLI must reject saved OAuth account overrides")
        } catch {
            #expect(error.localizedDescription ==
                "Antigravity CLI uses its local login and cannot select saved Google accounts. " +
                "Use --source auto or --source oauth with account selection.")
        }
    }
}
