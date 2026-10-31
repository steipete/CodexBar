import CodexBarCore
import Foundation
import Testing

struct CodexAccountNamesTests {
    @Test
    func `names follow a login and workspace across source and token changes`() {
        let original = Self.account(email: "USER@example.com", workspace: "team-a")
        let promoted = Self.account(
            email: "user@example.com",
            workspace: "team-a",
            source: .liveSystem,
            fingerprint: String(repeating: "b", count: 64))
        let otherLogin = Self.account(email: "other@example.com", workspace: "team-a")
        let otherWorkspace = Self.account(email: "user@example.com", workspace: "team-b")
        #expect(original.customNameKey == promoted.customNameKey)
        #expect(original.customNameKey != otherLogin.customNameKey)
        #expect(original.customNameKey != otherWorkspace.customNameKey)
    }

    @Test
    func `names survive config serialization and preserve account identity`() throws {
        let account = Self.account(email: "user@example.com", workspace: "team-a")
        var config = ProviderConfig(id: .codex)
        config.codexAccountNames = [account.customNameKey: "  School  "]
        let restored = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [account],
            activeVisibleAccountID: account.id,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
        let renamed = try #require(projection.applyingCustomNames(restored.codexAccountNames ?? [:])
            .visibleAccounts.first)
        #expect(renamed.displayName == "School")
        #expect(renamed.menuDisplayName == "School")
        #expect(renamed.withCustomName(nil) == account)
        #expect(projection.applyingCustomNames([:]) == projection)
    }

    @Test
    func `existing version one config and version three accounts need no name migration`() throws {
        let legacyConfig = Data(#"""
        {"version":1,"providers":[{"id":"codex","enabled":true,"source":"oauth",
        "hiddenUsageItemIDs":["section:codex-reset-credits"],
        "codexProfileHomePaths":["/tmp/example-profile"],
        "codexActiveSource":{"kind":"managedAccount","accountID":"11111111-1111-1111-1111-111111111111"}}]}
        """#.utf8)
        let registry = Data(#"""
        {"version":3,"accounts":[{"id":"11111111-1111-1111-1111-111111111111",
        "email":"user@example.com","workspaceAccountID":"team-a",
        "managedHomePath":"/tmp/example-managed","createdAt":1,"updatedAt":2,"lastAuthenticatedAt":2}]}
        """#.utf8)
        var config = try JSONDecoder().decode(CodexBarConfig.self, from: legacyConfig)
        let accounts = try JSONDecoder().decode(ManagedCodexAccountSet.self, from: registry)
        var provider = try #require(config.providerConfig(for: .codex))
        #expect(provider.codexAccountNames == nil)
        #expect(accounts.version == 3)
        #expect(accounts.accounts.first?.email == "user@example.com")
        let encoder = JSONEncoder()
        let original = try #require(JSONSerialization.jsonObject(with: encoder.encode(provider)) as? [String: Any])
        let account = Self.account(email: "user@example.com", workspace: "team-a")
        provider.codexAccountNames = [account.customNameKey: "School"]
        config.setProviderConfig(provider)
        let restored = try JSONDecoder().decode(CodexBarConfig.self, from: encoder.encode(config))
        let restoredProvider = try #require(restored.providerConfig(for: .codex))
        #expect(restored.version == 1)
        #expect(restoredProvider.codexAccountNames?[account.customNameKey] == "School")
        var unchanged = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(restoredProvider)) as? [String: Any])
        unchanged.removeValue(forKey: "codexAccountNames")
        #expect(NSDictionary(dictionary: original).isEqual(to: unchanged))
    }

    @Test
    func `empty names restore defaults and duplicate names stay distinguishable`() {
        let first = Self.account(email: "first@example.com", workspace: "team-a")
        let second = Self.account(email: "second@example.com", workspace: "team-a")
        #expect(first.withCustomName(" \n ").displayName == first.displayName)
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [first, second],
            activeVisibleAccountID: first.id,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
            .applyingCustomNames([first.customNameKey: "Work", second.customNameKey: "Work"])
        #expect(Set(projection.visibleAccounts.map(\.menuDisplayName)).count == 2)
    }

    @Test
    func `names survive workspace discovery without leaking to a sibling workspace`() throws {
        let savedID = UUID()
        let unknown = Self.account(email: "user@example.com", workspace: nil, storedID: savedID)
        let resolved = Self.account(email: "user@example.com", workspace: "team-a", storedID: savedID)
        let sibling = Self.account(email: "user@example.com", workspace: "team-b")
        let names = [unknown.customNameKey: "School"]
        let projection = CodexVisibleAccountProjection(
            visibleAccounts: [resolved, sibling],
            activeVisibleAccountID: resolved.id,
            liveVisibleAccountID: nil,
            hasUnreadableAddedAccountStore: false)
            .applyingCustomNames(names)
        let renamed = try #require(projection.visibleAccounts.first { $0.storedAccountID == savedID })
        #expect(renamed.customName == "School")
        #expect(projection.visibleAccounts.first { $0.storedAccountID == sibling.storedAccountID }?.customName == nil)
        let preferred = projection
            .applyingCustomNames(names.merging([resolved.customNameKey: "Work"]) { _, new in new })
        #expect(preferred.visibleAccounts.first { $0.storedAccountID == savedID }?.customName == "Work")
    }

    private static func account(
        email: String,
        workspace: String?,
        storedID: UUID = UUID(),
        source: CodexActiveSource = .managedAccount(id: UUID()),
        fingerprint: String = String(repeating: "a", count: 64)) -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: email,
            email: email,
            workspaceAccountID: workspace,
            authFingerprint: fingerprint,
            storedAccountID: storedID,
            selectionSource: source,
            isActive: true,
            isLive: source == .liveSystem,
            canReauthenticate: true,
            canRemove: true)
    }
}
