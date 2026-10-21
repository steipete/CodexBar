import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIServeAccountsTests {
    @Test
    func `empty account set encodes as an empty list`() throws {
        let payload = CLIServeAccountDiscovery.makePayload(
            config: CodexBarConfig(providers: []),
            managedCodexAccounts: [],
            identityMode: .full)

        #expect(payload.schemaVersion == 1)
        #expect(payload.accounts.isEmpty)
        let object = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect((object["accounts"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test
    func `projects managed and token accounts across providers with stable opaque ids`() throws {
        let managedID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let firstClaudeID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let secondClaudeID = try #require(UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA"))
        let openAIID = try #require(UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"))
        var codex = ProviderConfig(id: .codex, enabled: true)
        codex.codexActiveSource = .managedAccount(id: managedID)
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .claude,
                enabled: true,
                tokenAccounts: ProviderTokenAccountData(
                    version: 1,
                    accounts: [
                        Self.tokenAccount(id: firstClaudeID, label: "Claude One", token: "claude-secret-one"),
                        Self.tokenAccount(id: secondClaudeID, label: "Claude Two", token: "claude-secret-two"),
                    ],
                    activeIndex: 1)),
            codex,
            ProviderConfig(
                id: .openai,
                enabled: true,
                tokenAccounts: ProviderTokenAccountData(
                    version: 1,
                    accounts: [Self.tokenAccount(id: openAIID, label: "OpenAI", token: "openai-secret")],
                    activeIndex: 0)),
        ])
        let managed = Self.managedAccount(id: managedID)

        let payload = CLIServeAccountDiscovery.makePayload(
            config: config,
            managedCodexAccounts: [managed],
            identityMode: .full)

        #expect(payload.accounts.count == 4)
        #expect(payload.accounts.map(\.provider) == ["claude", "claude", "codex", "openai"])
        #expect(payload.accounts.map(\.id) == [
            "token-account:claude:\(firstClaudeID.uuidString.lowercased())",
            "token-account:claude:\(secondClaudeID.uuidString.lowercased())",
            "codex-managed:\(managedID.uuidString.lowercased())",
            "token-account:openai:\(openAIID.uuidString.lowercased())",
        ])
        #expect(payload.accounts.map(\.active) == [false, true, true, true])
        #expect(payload.accounts[2].label == "Example Workspace")
        #expect(payload.accounts[2].identity?.accountEmail == "managed@example.com")
    }

    @Test
    func `token account ids remain distinct across providers sharing a stored uuid`() throws {
        let sharedID = UUID()
        let token = Self.tokenAccount(id: sharedID, label: "Shared label", token: "synthetic-token")
        let config = CodexBarConfig(providers: [UsageProvider.claude, .openai].map { provider in
            ProviderConfig(
                id: provider.instanceID,
                tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [token], activeIndex: 0))
        })
        let full = CLIServeAccountDiscovery.makePayload(
            config: config, managedCodexAccounts: [], identityMode: .full)
        let redacted = CLIServeAccountDiscovery.makePayload(
            config: config, managedCodexAccounts: [], identityMode: .redacted)

        #expect(Set(full.accounts.map(\.id)).count == 2)
        #expect(full.accounts.map(\.id) == redacted.accounts.map(\.id))
        for account in full.accounts {
            let response = CLIServeAccountDiscovery.response(payload: full, requestedID: account.id)
            let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            #expect(object["provider"] as? String == account.provider)
        }
    }

    @Test
    func `wire payload excludes credential and internal storage fields and values`() throws {
        let tokenID = UUID()
        let managedID = UUID()
        let token = Self.tokenAccount(
            id: tokenID,
            label: "safe label",
            token: "TOP-SECRET-TOKEN",
            externalIdentifier: "private-login",
            organizationID: "private-org",
            workspaceID: "private-workspace",
            seatCreditEntitlement: "private-entitlement")
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .claude,
                apiKey: "TOP-SECRET-API-KEY",
                secretKey: "TOP-SECRET-SECRET-KEY",
                cookieHeader: "TOP-SECRET-COOKIE",
                tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [token], activeIndex: 0)),
        ])
        let managed = Self.managedAccount(
            id: managedID,
            authFingerprint: "credential-derived-fingerprint",
            managedHomePath: "/Users/private/managed-home")

        let payload = CLIServeAccountDiscovery.makePayload(
            config: config,
            managedCodexAccounts: [managed],
            identityMode: .full)
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))

        let object = try JSONSerialization.jsonObject(with: data)
        for forbiddenKey in [
            "token", "apiKey", "secretKey", "cookieHeader", "authFingerprint", "managedHomePath",
            "externalIdentifier", "organizationID", "organizationId", "workspaceID", "seatCreditEntitlement",
        ] {
            #expect(!Self.containsKey(forbiddenKey, in: object))
        }
        for forbiddenValue in [
            "TOP-SECRET", "private-login", "private-org", "private-workspace", "private-entitlement",
            "credential-derived-fingerprint", "/Users/private/managed-home",
        ] {
            #expect(!json.contains(forbiddenValue))
        }
    }

    @Test
    func `redacted identity hides email local parts in identity and fallback labels`() throws {
        let tokenID = UUID()
        let managedID = UUID()
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .claude,
                tokenAccounts: ProviderTokenAccountData(
                    version: 1,
                    accounts: [Self.tokenAccount(id: tokenID, label: "token.user@example.com", token: "secret")],
                    activeIndex: 0)),
        ])
        let managed = Self.managedAccount(id: managedID, workspaceLabel: nil)

        let payload = CLIServeAccountDiscovery.makePayload(
            config: config,
            managedCodexAccounts: [managed],
            identityMode: .redacted)

        #expect(payload.accounts.first { $0.provider == "claude" }?
            .label == "Account \(tokenID.uuidString.lowercased())")
        let codex = try #require(payload.accounts.first { $0.provider == "codex" })
        #expect(codex.label == "Account \(managedID.uuidString.lowercased())")
        #expect(codex.identity?.accountEmail == "redacted@example.com")
        let json = try #require(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        #expect(!json.contains("token.user"))
        #expect(!json.contains("managed@"))
    }

    @Test
    func `redacted labels use opaque account placeholders while full labels remain unchanged`() throws {
        let tokenID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let managedID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .claude,
                tokenAccounts: ProviderTokenAccountData(
                    version: 1,
                    accounts: [
                        Self.tokenAccount(id: tokenID, label: "Alice Smith", token: "secret"),
                    ],
                    activeIndex: 0)),
        ])
        let managed = Self.managedAccount(id: managedID, workspaceLabel: "Personal Workspace")

        let redacted = CLIServeAccountDiscovery.makePayload(
            config: config,
            managedCodexAccounts: [managed],
            identityMode: .redacted)
        let full = CLIServeAccountDiscovery.makePayload(
            config: config,
            managedCodexAccounts: [managed],
            identityMode: .full)

        #expect(redacted.accounts.first { $0.id == "token-account:claude:\(tokenID.uuidString.lowercased())" }?.label
            == "Account \(tokenID.uuidString.lowercased())")
        #expect(redacted.accounts.first { $0.id == "codex-managed:\(managedID.uuidString.lowercased())" }?.label
            == "Account \(managedID.uuidString.lowercased())")
        #expect(!redacted.accounts
            .contains { $0.label.contains("Alice Smith") || $0.label.contains("Personal Workspace") })
        #expect(full.accounts.first { $0.id == "token-account:claude:\(tokenID.uuidString.lowercased())" }?
            .label == "Alice Smith")
        #expect(full.accounts.first { $0.id == "codex-managed:\(managedID.uuidString.lowercased())" }?
            .label == "Personal Workspace")
    }

    @Test
    func `single account response returns matching account and unknown id returns 404`() throws {
        let accountID = UUID()
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .claude,
                tokenAccounts: ProviderTokenAccountData(
                    version: 1,
                    accounts: [Self.tokenAccount(id: accountID, label: "Claude", token: "secret")],
                    activeIndex: 0)),
        ])
        let payload = CLIServeAccountDiscovery.makePayload(
            config: config,
            managedCodexAccounts: [],
            identityMode: .full)
        let wireID = "token-account:claude:\(accountID.uuidString.lowercased())"

        let found = CLIServeAccountDiscovery.response(payload: payload, requestedID: wireID)
        #expect(found.status == .ok)
        let foundObject = try #require(JSONSerialization.jsonObject(with: found.body) as? [String: Any])
        #expect(foundObject["id"] as? String == wireID)

        let missing = CLIServeAccountDiscovery.response(payload: payload, requestedID: "unknown")
        #expect(missing.status == .notFound)
        let missingObject = try #require(JSONSerialization.jsonObject(with: missing.body) as? [String: Any])
        #expect(missingObject["error"] as? String == "account not found")
    }

    private static func containsKey(_ key: String, in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            return dictionary[key] != nil || dictionary.values.contains { self.containsKey(key, in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { self.containsKey(key, in: $0) }
        }
        return false
    }

    private static func tokenAccount(
        id: UUID,
        label: String,
        token: String,
        externalIdentifier: String? = nil,
        organizationID: String? = nil,
        workspaceID: String? = nil,
        seatCreditEntitlement: String? = nil) -> ProviderTokenAccount
    {
        ProviderTokenAccount(
            id: id,
            label: label,
            token: token,
            addedAt: 1,
            lastUsed: 2,
            externalIdentifier: externalIdentifier,
            organizationID: organizationID,
            workspaceID: workspaceID,
            seatCreditEntitlement: seatCreditEntitlement)
    }

    private static func managedAccount(
        id: UUID,
        workspaceLabel: String? = "Example Workspace",
        authFingerprint: String? = "fingerprint",
        managedHomePath: String = "/synthetic/managed-home") -> ManagedCodexAccount
    {
        ManagedCodexAccount(
            id: id,
            email: "managed@example.com",
            providerAccountID: "provider-account",
            workspaceLabel: workspaceLabel,
            workspaceAccountID: "workspace-account",
            authFingerprint: authFingerprint,
            managedHomePath: managedHomePath,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
    }
}
