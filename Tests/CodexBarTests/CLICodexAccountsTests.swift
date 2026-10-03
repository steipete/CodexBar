import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLICodexAccountsTests {
    @Test
    func `account commands parse explicit selectors and advertise platform boundaries`() throws {
        let program = Program(descriptors: CodexBarCLI.commandDescriptors())
        let list = try program.resolve(argv: ["codex-accounts", "--json"])
        #expect(list.path == ["codex-accounts", "list"])
        #expect(list.parsedValues.flags.contains("jsonShortcut"))
        let id = UUID().uuidString
        let promote = try program.resolve(argv: ["codex-accounts", "promote", id, "--json"])
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

    private static func account(email: String) -> ManagedCodexAccount {
        ManagedCodexAccount(
            id: UUID(),
            email: email,
            providerAccountID: "account-synthetic",
            managedHomePath: "/synthetic/home",
            createdAt: 0,
            updatedAt: 0,
            lastAuthenticatedAt: nil)
    }
}
