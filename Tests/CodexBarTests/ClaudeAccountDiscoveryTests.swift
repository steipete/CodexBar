import CodexBarCore
import Foundation
import Testing

struct ClaudeAccountDiscoveryTests {
    @Test
    func `default claude dir maps to the bare keychain service`() {
        let service = ClaudeAccountDiscovery.keychainServiceName(
            forConfigDirectory: "/Users/x/.claude",
            defaultClaudeDirectory: "/Users/x/.claude")
        #expect(service == "Claude Code-credentials")
    }

    @Test
    func `config dir maps to a suffixed keychain service`() {
        let service = ClaudeAccountDiscovery.keychainServiceName(
            forConfigDirectory: "/Users/x/.claude-acct2",
            defaultClaudeDirectory: "/Users/x/.claude")
        #expect(service.hasPrefix("Claude Code-credentials-"))
        let suffix = service.dropFirst("Claude Code-credentials-".count)
        #expect(suffix.count == 8)
        #expect(suffix.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    }

    @Test
    func `service mapping is deterministic and dir-specific`() {
        let a1 = ClaudeAccountDiscovery.keychainServiceName(
            forConfigDirectory: "/Users/x/.claude-acct2", defaultClaudeDirectory: "/Users/x/.claude")
        let a2 = ClaudeAccountDiscovery.keychainServiceName(
            forConfigDirectory: "/Users/x/.claude-acct2", defaultClaudeDirectory: "/Users/x/.claude")
        let b = ClaudeAccountDiscovery.keychainServiceName(
            forConfigDirectory: "/Users/x/.claude-acct3", defaultClaudeDirectory: "/Users/x/.claude")
        #expect(a1 == a2)
        #expect(a1 != b)
    }

    @Test
    func `discover enumerates dirs as file or keychain sources`() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("cb-claude-discovery-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }

        // .claude (keychain — no file), .claude-acct2 (keychain), .claude-acct3 (file)
        for sub in [".claude", ".claude-acct2", ".claude-acct3"] {
            try fm.createDirectory(
                at: home.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let acct3Creds = home.appendingPathComponent(".claude-acct3/.credentials.json")
        try Data("{}".utf8).write(to: acct3Creds)
        // a non-claude dir must be ignored
        try fm.createDirectory(
            at: home.appendingPathComponent(".config"), withIntermediateDirectories: true)

        let accounts = ClaudeAccountDiscovery.discover(homeDirectory: home.path, fileManager: fm)
        #expect(accounts.count == 3)

        let byLabel = Dictionary(uniqueKeysWithValues: accounts.map { ($0.label, $0.source) })
        #expect(byLabel["Claude"] == .keychainService(service: "Claude Code-credentials", account: nil))
        if case let .keychainService(service, _)? = byLabel["acct2"] {
            #expect(service.hasPrefix("Claude Code-credentials-"))
        } else {
            Issue.record("acct2 should be a keychain source")
        }
        if case let .credentialsFile(path)? = byLabel["acct3"] {
            #expect(path.hasSuffix(".claude-acct3/.credentials.json"))
        } else {
            Issue.record("acct3 should be a file source")
        }
    }
}
