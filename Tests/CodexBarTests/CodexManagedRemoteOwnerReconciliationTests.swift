import CodexBarCore
import Foundation
import Testing

@Suite(.serialized, CodexCredentialFixtures())
struct CodexManagedRemoteOwnerReconciliationTests {
    @Test
    func `selected managed workspace does not collapse into auth default live account`() throws {
        let managedHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "member@example.com",
            accountID: "auth-default")
        let fingerprint = try #require(CodexAuthFingerprint.fingerprint(homePath: managedHome.path))
        let stored = ManagedCodexAccount(
            id: UUID(),
            email: "member@example.com",
            providerAccountID: "selected-workspace",
            workspaceLabel: "Selected",
            workspaceAccountID: nil,
            authFingerprint: fingerprint,
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let live = ObservedSystemCodexAccount(
            email: "member@example.com",
            workspaceLabel: "Default",
            workspaceAccountID: "auth-default",
            authFingerprint: fingerprint,
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .providerAccount(id: "auth-default"))
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { ManagedCodexAccountSet(version: 1, accounts: [stored]) },
            systemObserver: SelectedWorkspaceSystemObserver(account: live),
            activeSource: .managedAccount(id: stored.id),
            baseEnvironment: [:])

        let snapshot = reconciler.loadSnapshot()
        let resolution = CodexActiveSourceResolver.resolve(from: snapshot)
        let projection = CodexVisibleAccountProjection.make(from: snapshot)
        let knownOwners = CodexKnownOwnerCatalog.candidates(from: snapshot)

        #expect(snapshot.managedRemoteIdentity(for: stored) == .providerAccount(id: "selected-workspace"))
        #expect(snapshot.matchingStoredAccountForLiveSystemAccount == nil)
        #expect(resolution.resolvedSource == .managedAccount(id: stored.id))
        #expect(projection.visibleAccounts.count == 2)
        #expect(projection.visibleAccounts.first { $0.selectionSource == .managedAccount(id: stored.id) }?
            .workspaceAccountID == "selected-workspace")
        #expect(projection.visibleAccounts.first { $0.selectionSource == .liveSystem }?
            .workspaceAccountID == "auth-default")
        #expect(knownOwners.contains { $0.identity == .providerAccount(id: "selected-workspace") })
        #expect(knownOwners.contains { $0.identity == .providerAccount(id: "auth-default") })
    }

    @Test
    func `managed auth default remains a dashboard owner without live or profile evidence`() throws {
        let managedHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "member@example.com",
            accountID: "auth-default")
        let stored = ManagedCodexAccount(
            id: UUID(),
            email: "member@example.com",
            providerAccountID: "selected-workspace",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { ManagedCodexAccountSet(version: 1, accounts: [stored]) },
            systemObserver: SelectedWorkspaceSystemObserver(account: nil),
            activeSource: .managedAccount(id: stored.id),
            baseEnvironment: [:])

        let snapshot = reconciler.loadSnapshot()
        let knownOwners = CodexKnownOwnerCatalog.candidates(from: snapshot)
        let decision = CodexDashboardAuthority.evaluate(CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: snapshot.managedRemoteIdentity(for: stored),
                expectedScopedEmail: "member@example.com",
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "member@example.com",
                knownOwners: knownOwners),
            routing: CodexDashboardRoutingHints(
                targetEmail: "member@example.com",
                lastKnownDashboardRoutingEmail: nil)))

        #expect(snapshot.liveSystemAccount == nil)
        #expect(snapshot.profileHomeAccounts.isEmpty)
        #expect(knownOwners.contains { $0.identity == .providerAccount(id: "selected-workspace") })
        #expect(knownOwners.contains { $0.identity == .providerAccount(id: "auth-default") })
        #expect(decision.disposition == .displayOnly)
        #expect(decision.reason == .sameEmailAmbiguity(email: "member@example.com"))
        #expect(decision.allowedEffects.isEmpty)
    }

    @Test
    func `managed email only auth remains a dashboard owner without live or profile evidence`() throws {
        let managedHome = CodexCredentialFixtures.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "member@example.com",
            accountID: nil)
        let stored = ManagedCodexAccount(
            id: UUID(),
            email: "member@example.com",
            workspaceAccountID: "selected-workspace",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { ManagedCodexAccountSet(version: 1, accounts: [stored]) },
            systemObserver: SelectedWorkspaceSystemObserver(account: nil),
            activeSource: .managedAccount(id: stored.id),
            baseEnvironment: [:])

        let snapshot = reconciler.loadSnapshot()
        let knownOwners = CodexKnownOwnerCatalog.candidates(from: snapshot)
        let decision = CodexDashboardAuthority.evaluate(CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: snapshot.managedRemoteIdentity(for: stored),
                expectedScopedEmail: "member@example.com",
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "member@example.com",
                knownOwners: knownOwners),
            routing: CodexDashboardRoutingHints(
                targetEmail: "member@example.com",
                lastKnownDashboardRoutingEmail: nil)))

        #expect(snapshot.liveSystemAccount == nil)
        #expect(snapshot.profileHomeAccounts.isEmpty)
        #expect(snapshot.runtimeIdentity(for: stored) == .emailOnly(normalizedEmail: "member@example.com"))
        #expect(knownOwners.contains { $0.identity == .providerAccount(id: "selected-workspace") })
        #expect(knownOwners.contains { $0.identity == .emailOnly(normalizedEmail: "member@example.com") })
        #expect(decision.disposition == .displayOnly)
        #expect(decision.reason == .sameEmailAmbiguity(email: "member@example.com"))
        #expect(decision.allowedEffects.isEmpty)
    }

    private static func writeCodexAuthFile(homeURL: URL, email: String, accountID: String?) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none"])
        var authClaims: [String: Any] = ["chatgpt_plan_type": "business"]
        if let accountID {
            authClaims["chatgpt_account_id"] = accountID
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "https://api.openai.com/auth": authClaims,
        ])
        let idToken = "\(Self.base64URL(header)).\(Self.base64URL(payload))."
        var tokens: [String: Any] = [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": idToken,
        ]
        if let accountID {
            tokens["account_id"] = accountID
        }
        let data = try JSONSerialization.data(withJSONObject: ["tokens": tokens])
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}

private struct SelectedWorkspaceSystemObserver: CodexSystemAccountObserving {
    let account: ObservedSystemCodexAccount?

    func loadSystemAccount(environment _: [String: String]) throws -> ObservedSystemCodexAccount? {
        self.account
    }
}
