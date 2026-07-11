import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexLimitResetOwnerKeyTests {
    @Test
    func `limit reset owner stays stable for the same provider workspace and email`() throws {
        let store = self.makeLimitResetOwnerStore(suffix: "provider-stability")
        let original = self.limitResetVisibleAccount(
            id: "original-row",
            email: " Person-One@Example.Test ",
            workspaceLabel: "Fixture Team",
            workspaceAccountID: "workspace-fixture-stable",
            authFingerprint: "auth-fixture-old")
        let relabeled = self.limitResetVisibleAccount(
            id: "relabeled-row",
            email: "person-one@example.test",
            workspaceLabel: "Renamed Fixture Team",
            workspaceAccountID: " workspace-fixture-stable ",
            authFingerprint: "auth-fixture-new")

        let originalKey = try #require(store.codexLimitResetOwnerKey(
            forVisibleAccount: original,
            visibleAccounts: [original]))
        let relabeledKey = try #require(store.codexLimitResetOwnerKey(
            forVisibleAccount: relabeled,
            visibleAccounts: [relabeled]))

        #expect(originalKey == relabeledKey)
        self.expectOpaqueLimitResetOwnerKey(
            originalKey,
            excludes: ["workspace-fixture-stable", "person-one@example.test"])
    }

    @Test
    func `different emails in the same provider workspace use different owner keys`() throws {
        let store = self.makeLimitResetOwnerStore(suffix: "provider-member-distinct")
        let first = self.limitResetVisibleAccount(
            id: "first-member",
            email: "first-member@example.test",
            workspaceAccountID: "workspace-fixture-shared")
        let second = self.limitResetVisibleAccount(
            id: "second-member",
            email: "second-member@example.test",
            workspaceAccountID: "workspace-fixture-shared")

        let firstKey = try #require(store.codexLimitResetOwnerKey(
            forVisibleAccount: first,
            visibleAccounts: [first, second]))
        let secondKey = try #require(store.codexLimitResetOwnerKey(
            forVisibleAccount: second,
            visibleAccounts: [first, second]))

        #expect(firstKey != secondKey)
    }

    @Test
    func `different provider workspaces with the same email use different owner keys`() throws {
        let store = self.makeLimitResetOwnerStore(suffix: "provider-distinct")
        let first = self.limitResetVisibleAccount(
            id: "first-row",
            email: "shared-person@example.test",
            workspaceAccountID: "workspace-fixture-one")
        let second = self.limitResetVisibleAccount(
            id: "second-row",
            email: "shared-person@example.test",
            workspaceAccountID: "workspace-fixture-two")
        let visibleAccounts = [first, second]

        let firstKey = try #require(store.codexLimitResetOwnerKey(
            forVisibleAccount: first,
            visibleAccounts: visibleAccounts))
        let secondKey = try #require(store.codexLimitResetOwnerKey(
            forVisibleAccount: second,
            visibleAccounts: visibleAccounts))

        #expect(firstKey != secondKey)
        self.expectOpaqueLimitResetOwnerKey(firstKey, excludes: ["workspace-fixture-one", "shared-person@example.test"])
        self.expectOpaqueLimitResetOwnerKey(
            secondKey,
            excludes: ["workspace-fixture-two", "shared-person@example.test"])
    }

    @Test
    func `email only owner fails closed even for one visible row`() {
        let store = self.makeLimitResetOwnerStore(suffix: "email-unique")
        let account = self.limitResetVisibleAccount(
            id: "email-row-original",
            email: " Unique-Person@Example.Test ",
            workspaceLabel: "Fixture Personal",
            authFingerprint: "auth-fixture-old")

        #expect(store.codexLimitResetOwnerKey(forVisibleAccount: account, visibleAccounts: [account]) == nil)
        #expect(CodexLimitResetOwnerKey(
            identity: .emailOnly(normalizedEmail: "unique-person@example.test"),
            accountEmail: "unique-person@example.test") == nil)
    }

    @Test
    func `duplicate email only rows fail closed`() {
        let store = self.makeLimitResetOwnerStore(suffix: "email-ambiguous")
        let first = self.limitResetVisibleAccount(
            id: "email-row-one",
            email: "ambiguous-person@example.test")
        let second = self.limitResetVisibleAccount(
            id: "email-row-two",
            email: " Ambiguous-Person@Example.Test ")
        let visibleAccounts = [first, second]

        #expect(store.codexLimitResetOwnerKey(forVisibleAccount: first, visibleAccounts: visibleAccounts) == nil)
        #expect(store.codexLimitResetOwnerKey(forVisibleAccount: second, visibleAccounts: visibleAccounts) == nil)
    }

    @Test
    func `provider row wins its own identity while same email fallback fails closed`() throws {
        let store = self.makeLimitResetOwnerStore(suffix: "mixed-identity")
        let providerBacked = self.limitResetVisibleAccount(
            id: "provider-row",
            email: "mixed-person@example.test",
            workspaceAccountID: "workspace-fixture-provider")
        let emailOnly = self.limitResetVisibleAccount(
            id: "email-row",
            email: "mixed-person@example.test")
        let visibleAccounts = [providerBacked, emailOnly]

        let providerKey = try #require(store.codexLimitResetOwnerKey(
            forVisibleAccount: providerBacked,
            visibleAccounts: visibleAccounts))

        #expect(providerKey == CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "workspace-fixture-provider"),
            accountEmail: "mixed-person@example.test"))
        #expect(store.codexLimitResetOwnerKey(forVisibleAccount: emailOnly, visibleAccounts: visibleAccounts) == nil)
    }

    @Test
    func `guard and visible row normalize the same provider owner`() throws {
        let store = self.makeLimitResetOwnerStore(suffix: "provider-normalization")
        let account = self.limitResetVisibleAccount(
            id: "provider-row",
            email: "provider-person@example.test",
            workspaceAccountID: " workspace-fixture-mixed-case ")
        let guardValue = CodexAccountScopedRefreshGuard(
            source: account.selectionSource,
            identity: .providerAccount(id: " WORKSPACE-FIXTURE-MIXED-CASE "),
            accountKey: account.email)

        let visibleKey = try #require(store.codexLimitResetOwnerKey(
            forVisibleAccount: account,
            visibleAccounts: [account]))
        let guardKey = try #require(store.codexLimitResetOwnerKey(
            expectedGuard: guardValue,
            visibleAccounts: [account]))

        #expect(visibleKey == guardKey)
    }

    @Test
    func `unresolved owner identity fails closed`() {
        let store = self.makeLimitResetOwnerStore(suffix: "unresolved")
        let guardValue = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: .unresolved,
            accountKey: nil)
        let unresolvedRow = self.limitResetVisibleAccount(id: "unresolved-row", email: "   ")

        #expect(store.codexLimitResetOwnerKey(expectedGuard: guardValue, visibleAccounts: []) == nil)
        #expect(store.codexLimitResetOwnerKey(
            forVisibleAccount: unresolvedRow,
            visibleAccounts: [unresolvedRow]) == nil)
    }

    private func makeLimitResetOwnerStore(suffix: String) -> UsageStore {
        let support = CodexAccountScopedRefreshTests()
        let settings = support.makeSettingsStore(suite: "CodexLimitResetOwnerKeyTests-\(suffix)")
        return support.makeUsageStore(settings: settings)
    }

    private func limitResetVisibleAccount(
        id: String,
        email: String,
        workspaceLabel: String? = nil,
        workspaceAccountID: String? = nil,
        authFingerprint: String? = nil) -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: id,
            email: email,
            workspaceLabel: workspaceLabel,
            workspaceAccountID: workspaceAccountID,
            authFingerprint: authFingerprint,
            storedAccountID: nil,
            selectionSource: .profileHome(path: "/tmp/\(id)"),
            isActive: false,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
    }

    private func expectOpaqueLimitResetOwnerKey(
        _ key: CodexLimitResetOwnerKey,
        excludes cleartextValues: [String],
        sourceLocation: SourceLocation = #_sourceLocation)
    {
        #expect(
            key.rawValue.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
            sourceLocation: sourceLocation)
        for cleartextValue in cleartextValues {
            #expect(!key.rawValue.contains(cleartextValue), sourceLocation: sourceLocation)
        }
    }
}
