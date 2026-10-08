import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct CodexAccountPromotionPreparationTests {
    @Test
    func `builder carries direct auth identities for target and live`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPreparationTests-direct-identities",
            workspaceIdentities: [
                "acct-alpha": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "acct-alpha",
                    workspaceLabel: "Personal"),
                "acct-beta": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "acct-beta",
                    workspaceLabel: "Team"),
            ])
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        _ = try container.writeLiveOAuthAuthFile(email: "alpha@example.com", accountID: "acct-alpha")

        let builder = PreparedPromotionContextBuilder(
            store: container.fileStore,
            workspaceResolver: container.workspaceResolver,
            snapshotLoader: container.settings,
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            baseEnvironment: container.baseEnvironment,
            fileManager: .default)

        let context = try await builder.build(targetID: target.id)

        #expect(context.target.authIdentity?.identity == .providerAccount(id: "acct-beta"))
        #expect(context.target.authIdentity?.workspaceLabel == "Team")
        #expect(context.live.authIdentity?.identity == .providerAccount(id: "acct-alpha"))
        #expect(context.live.authIdentity?.workspaceLabel == "Personal")
    }

    @Test
    func `builder preserves target missing auth as degraded home state`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPreparationTests-target-missing-auth")
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: target.managedHomePath, isDirectory: true)
                .appendingPathComponent("auth.json", isDirectory: false))

        let builder = PreparedPromotionContextBuilder(
            store: container.fileStore,
            workspaceResolver: container.workspaceResolver,
            snapshotLoader: container.settings,
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            baseEnvironment: container.baseEnvironment,
            fileManager: .default)

        let context = try await builder.build(targetID: target.id)

        switch context.target.homeState {
        case let .missing(homeURL):
            #expect(homeURL.path == target.managedHomePath)
        case .readable, .unreadable:
            Issue.record("Expected target auth to be represented as missing")
        }
        #expect(context.target.authIdentity == nil)
        #expect(context.target.persistedIdentity.identity == .providerAccount(id: "acct-beta"))
    }

    @Test
    func `builder keeps persisted and direct home identity views separate`() async throws {
        let container = try CodexAccountPromotionTestContainer(
            suiteName: "CodexAccountPromotionPreparationTests-persisted-vs-direct",
            workspaceIdentities: [
                "acct-alpha": CodexOpenAIWorkspaceIdentity(
                    workspaceAccountID: "acct-alpha",
                    workspaceLabel: "Personal"),
            ])
        defer { container.tearDown() }

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        let legacy = try container.createManagedAccount(
            persistedEmail: "legacy@example.com",
            authEmail: "alpha@example.com",
            authAccountID: "acct-alpha",
            persistedProviderAccountID: nil,
            useAuthAccountIDAsPersistedProviderAccountID: false)
        try container.persistAccounts([target, legacy])

        let builder = PreparedPromotionContextBuilder(
            store: container.fileStore,
            workspaceResolver: container.workspaceResolver,
            snapshotLoader: container.settings,
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            baseEnvironment: container.baseEnvironment,
            fileManager: .default)

        let context = try await builder.build(targetID: target.id)
        let preparedLegacy = try #require(context.storedManagedAccounts.first(where: { $0.persisted.id == legacy.id }))

        #expect(preparedLegacy.persistedIdentity.email == "legacy@example.com")
        #expect(preparedLegacy.persistedIdentity.identity == .providerAccount(id: "acct-alpha"))
        #expect(preparedLegacy.authIdentity?.email == "alpha@example.com")
        #expect(preparedLegacy.authIdentity?.identity == .providerAccount(id: "acct-alpha"))
        #expect(preparedLegacy.authIdentity?.workspaceLabel == "Personal")
        #expect(preparedLegacy.remoteIdentity.email == "alpha@example.com")
    }

    @Test
    func `runtime account preserves historical email precedence`() throws {
        let cases: [(name: String, topLevel: Any?, profile: Any?, expectedEmail: String?)] = [
            ("top-level email only", " Top@Example.COM ", nil, "top@example.com"),
            ("profile email only", nil, " Profile@Example.COM ", "profile@example.com"),
            ("matching claims", " Match@Example.COM ", "match@example.com", "match@example.com"),
            (
                "conflicting claims preserve top-level precedence",
                "top@example.com", "profile@example.com", "top@example.com"),
            ("malformed top-level claim falls back to profile", 42, "profile@example.com", "profile@example.com"),
            ("malformed profile claim does not override valid top-level", "top@example.com", 42, "top@example.com"),
            ("missing top-level claim uses profile", nil, "profile@example.com", "profile@example.com"),
            ("missing profile claim preserves top-level", "top@example.com", nil, "top@example.com"),
            ("missing claims", nil, nil, nil),
            (
                "case and whitespace normalize after top-level selection",
                " Top@Example.COM ", " top@example.com ", "top@example.com"),
        ]
        for candidate in cases {
            var payload: [String: Any] = [:]
            if let topLevel = candidate.topLevel {
                payload["email"] = topLevel
            }
            if let profile = candidate.profile {
                payload["https://api.openai.com/profile"] = ["email": profile]
            }
            let rawData = try JSONSerialization.data(
                withJSONObject: ["tokens": ["id_token": Self.jwt(payload: payload)]])
            let account = try PreparedPromotionContextBuilder.runtimeAccount(from: rawData)
            #expect(account.email == candidate.expectedEmail, "Scenario: \(candidate.name)")
        }
    }

    private static func jwt(payload: [String: Any]) throws -> String {
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let encoded = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "synthetic.\(encoded).signature"
    }
}
