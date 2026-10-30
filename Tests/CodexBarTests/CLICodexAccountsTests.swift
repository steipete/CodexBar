import Commander
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct CLICodexAccountsTests {
    @Test
    func `account commands parse explicit selectors and advertise platform boundaries`() throws {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        let list = try program.resolve(arguments: ["codex-accounts", "--json"])
        #expect(list.path == ["codex-accounts", "list"])
        #expect(list.parsedValues.flags.contains("jsonShortcut"))
        let id = UUID().uuidString
        let promote = try program.resolve(arguments: ["codex-accounts", "promote", id, "--json"])
        #expect(promote.path == ["codex-accounts", "promote"])
        #expect(promote.parsedValues.positional == [id])
        #expect(CodexBarCLI.codexAccountsHelp(version: "synthetic").contains("macOS only"))
    }

    @Test
    func `promotion selector rejects ambiguous emails and accepts only exact UUIDs`() throws {
        let first = Self.account(email: "same@example.com")
        let second = Self.account(email: "SAME@example.com")
        let accounts = [first, second]
        #expect(throws: CodexAccountCLIError.ambiguousAccount) {
            try CodexBarCLI.resolveCodexAccount(selector: "same@example.com", accounts: accounts)
        }
        #expect(try CodexBarCLI.resolveCodexAccount(selector: first.id.uuidString, accounts: accounts).id == first.id)
        #expect(throws: CodexAccountCLIError.unknownAccount) {
            try CodexBarCLI.resolveCodexAccount(selector: String(first.id.uuidString.prefix(8)), accounts: accounts)
        }
    }

    @Test
    func `account list serializes only identities and current system marker`() throws {
        let account = Self.account(email: "synthetic@example.com")
        let live = CodexAuthBackedAccount(
            identity: .providerAccount(id: "account-synthetic"), email: "synthetic@example.com", plan: nil)
        let rows = CodexBarCLI.codexAccountRows(accounts: [account], live: live, runtimeAccounts: [account.id: live])
        #expect(rows.first?.isSystemAccount == true)
        #expect(CodexBarCLI.codexAccountRows(accounts: [account], live: live).first?.isSystemAccount == false)
        let data = try JSONEncoder().encode(rows)
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(!json.contains("managedHomePath"))
        #expect(!json.contains("authFingerprint"))
        #expect(!json.contains("tokens"))
    }

    @Test(arguments: [false, true])
    func `promotion resolves latest selector before any auth replacement`(removed: Bool) async throws {
        let container = try CodexAccountPromotionTestContainer(suiteName: "CLIAccounts-latest-selector")
        defer { container.tearDown() }
        let first = try container.createManagedAccount(persistedEmail: "same@example.com", authAccountID: "first")
        try container.persistAccounts([first])
        let stale = try container.loadAccounts().accounts
        #expect(try CodexBarCLI.resolveCodexAccount(selector: first.email, accounts: stale).id == first.id)
        let live = try container.writeLiveOAuthAuthFile(email: "original@example.com", accountID: "original")
        let second = try container.createManagedAccount(persistedEmail: first.email, authAccountID: "second")
        try container.persistAccounts(removed ? [] : [first, second])
        let swapper = RecordingCodexLiveAuthSwapper()
        let transaction = CodexAccountPromotionTransaction(
            store: container.fileStore,
            homeFactory: container.homeFactory,
            workspaceResolver: container.workspaceResolver,
            snapshotLoader: container.settings,
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            liveAuthSwapper: swapper,
            baseEnvironment: container.baseEnvironment)
        await #expect(throws: removed ? CodexAccountCLIError.unknownAccount : CodexAccountCLIError.ambiguousAccount) {
            try await transaction.promoteManagedAccount(resolveTargetID: { latest in
                try CodexBarCLI.resolveCodexAccount(selector: first.email, accounts: latest).id
            })
        }
        #expect(swapper.swapCallCount == 0)
        #expect(try container.liveAuthData() == live)
    }

    @Test(arguments: [false, true])
    func `listing retains metadata when individual credentials or live auth are broken`(brokenLive: Bool) {
        let healthy = Self.account(email: "healthy@example.com")
        let unreadable = Self.account(email: "unreadable@example.com")
        let malformed = Self.account(email: "malformed@example.com")
        let liveHome = URL(fileURLWithPath: "/synthetic/live")
        let data = Data(#"{"tokens":{"accountId":"account-synthetic"}}"#.utf8)
        let reader = AccountListFixtureReader(data: [
            healthy.managedHomePath: data,
            malformed.managedHomePath: Data("malformed".utf8),
            liveHome.path: brokenLive ? Data("malformed".utf8) : data,
        ], unreadablePath: unreadable.managedHomePath)
        let rows = CodexBarCLI.codexAccountRows(
            accounts: [healthy, unreadable, malformed], liveHome: liveHome, reader: reader)
        #expect(rows.map(\.email) == [healthy.email, unreadable.email, malformed.email])
        #expect(rows.map(\.isSystemAccount) == [!brokenLive, false, false])
    }

    private static func account(email: String) -> ManagedCodexAccount {
        ManagedCodexAccount(
            id: UUID(),
            email: email,
            providerAccountID: "account-synthetic",
            managedHomePath: "/synthetic/" + UUID().uuidString,
            createdAt: 0,
            updatedAt: 0,
            lastAuthenticatedAt: nil)
    }
}

private struct AccountListFixtureReader: CodexAuthMaterialReading {
    let data: [String: Data]
    let unreadablePath: String
    func readAuthData(homeURL: URL) throws -> Data? {
        if homeURL.path == self.unreadablePath { throw CocoaError(.fileReadNoPermission) }
        return self.data[homeURL.path]
    }
}
