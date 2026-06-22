import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeAccountDiscoveryTests {
    @Test
    func `default dir maps to the bare keychain service`() {
        #expect(ClaudeAccountDiscovery.keychainServiceName(
            forConfigDirectory: "/Users/x/.claude",
            defaultClaudeDirectory: "/Users/x/.claude") == "Claude Code-credentials")
    }

    @Test
    func `config dir maps to an 8-hex suffixed service`() {
        let service = ClaudeAccountDiscovery.keychainServiceName(
            forConfigDirectory: "/Users/x/.claude-acct2",
            defaultClaudeDirectory: "/Users/x/.claude")
        #expect(service.hasPrefix("Claude Code-credentials-"))
        #expect(service.dropFirst("Claude Code-credentials-".count).count == 8)
    }

    @Test
    func `assemble lists default first, then recent services labelled from dirs`() {
        let acct2 = ClaudeAccountDiscovery.keychainServiceName(
            forConfigDirectory: "/Users/x/.claude-acct2", defaultClaudeDirectory: "/Users/x/.claude")
        let accounts = ClaudeAccountDiscovery.assemble(
            homeDirectory: "/Users/x",
            configDirectories: ["/Users/x/.claude", "/Users/x/.claude-acct2"],
            fileCredsDirectories: [],
            keychainServicesNewestFirst: ["Claude Code-credentials", acct2, "Claude Code-credentials-deadbeef"],
            maxAccounts: 4)
        #expect(accounts.count == 3)
        #expect(accounts[0].label == "Claude")
        #expect(accounts[0].source == .keychainService(service: "Claude Code-credentials", account: nil))
        #expect(accounts[1].source == .keychainService(service: acct2, account: nil))
        #expect(accounts[1].label == "acct2") // reverse-mapped from the dir
        #expect(accounts[2].label == "Claude deadbeef") // unknown service -> suffix label
    }

    @Test
    func `assemble caps the number of suffixed accounts`() {
        let accounts = ClaudeAccountDiscovery.assemble(
            homeDirectory: "/Users/x",
            configDirectories: ["/Users/x/.claude"],
            fileCredsDirectories: [],
            keychainServicesNewestFirst: [
                "Claude Code-credentials",
                "Claude Code-credentials-aaaaaaaa",
                "Claude Code-credentials-bbbbbbbb",
                "Claude Code-credentials-cccccccc",
            ],
            maxAccounts: 2)
        #expect(accounts.count == 2) // default + 1 suffixed
        #expect(accounts[0].label == "Claude")
    }

    @Test
    func `assemble prefers a file source for a dir that has one`() {
        let accounts = ClaudeAccountDiscovery.assemble(
            homeDirectory: "/Users/x",
            configDirectories: ["/Users/x/.claude-acct3"],
            fileCredsDirectories: ["/Users/x/.claude-acct3"],
            keychainServicesNewestFirst: [],
            maxAccounts: 4)
        #expect(accounts.count == 1)
        #expect(accounts[0].source == .credentialsFile(path: "/Users/x/.claude-acct3/.credentials.json"))
        #expect(accounts[0].label == "acct3")
    }
}
