import Foundation
import Testing
@testable import CodexBarCore

struct OpenCodeWorkspaceAccountsTests {
    @Test
    func canonicalIDsDistinguishWorkspacesWhileRemainingStableForSamePair() throws {
        let tokenAccountID = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let first = try #require(OpenCodeWorkspaceAccount(
            tokenAccountID: tokenAccountID,
            workspaceID: "https://opencode.ai/workspace/wrk_ALPHA/billing",
            label: "Alpha",
            now: Date(timeIntervalSince1970: 100)))
        let same = try #require(OpenCodeWorkspaceAccount(
            tokenAccountID: tokenAccountID,
            workspaceID: "wrk_ALPHA",
            label: "Renamed",
            now: Date(timeIntervalSince1970: 200)))
        let second = try #require(OpenCodeWorkspaceAccount(
            tokenAccountID: tokenAccountID,
            workspaceID: "wrk_BETA",
            label: "Beta",
            now: Date(timeIntervalSince1970: 100)))

        #expect(first.id == same.id)
        #expect(first.id != second.id)
        #expect(first.workspaceID == "wrk_ALPHA")
    }

    @Test
    func deduplicatesAccountsAndPreservesActiveWorkspace() throws {
        let tokenAccountID = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        let alpha = try #require(OpenCodeWorkspaceAccount(
            tokenAccountID: tokenAccountID,
            workspaceID: "wrk_ALPHA",
            label: "Alpha",
            now: Date(timeIntervalSince1970: 100)))
        let beta = try #require(OpenCodeWorkspaceAccount(
            tokenAccountID: tokenAccountID,
            workspaceID: "wrk_BETA",
            label: "Beta",
            now: Date(timeIntervalSince1970: 200)))
        var accounts = OpenCodeWorkspaceAccounts(accounts: [alpha])

        #expect(accounts.upsert(alpha) == .duplicate)
        #expect(accounts.upsert(beta) == .saved)
        let selected = accounts.selectActive(id: beta.id)
        #expect(selected)
        #expect(accounts.active?.id == beta.id)
    }

    @Test
    func pruningRemovesDeletedTokenAccountsAndFallsBackDeterministically() throws {
        let firstToken = try #require(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        let secondToken = try #require(UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
        let first = try #require(OpenCodeWorkspaceAccount(
            tokenAccountID: firstToken,
            workspaceID: "wrk_ALPHA",
            label: "Alpha",
            now: Date(timeIntervalSince1970: 100)))
        let second = try #require(OpenCodeWorkspaceAccount(
            tokenAccountID: secondToken,
            workspaceID: "wrk_BETA",
            label: "Beta",
            now: Date(timeIntervalSince1970: 200)))
        var accounts = OpenCodeWorkspaceAccounts(accounts: [first, second], activeID: second.id)

        accounts.prune(validTokenAccountIDs: [firstToken])

        #expect(accounts.accounts.map(\.id) == [first.id])
        #expect(accounts.active?.id == first.id)
    }

    @Test
    func invalidAndMissingCredentialsHaveExplicitMutationResults() {
        var accounts = OpenCodeWorkspaceAccounts()

        #expect(accounts.add(
            tokenAccountID: nil,
            workspaceID: "wrk_ALPHA",
            label: "Alpha") == .missingReusableCredential)
        #expect(accounts.add(
            tokenAccountID: UUID(),
            workspaceID: "not-a-workspace",
            label: "Invalid") == .invalidWorkspaceID)
    }

    @Test
    func persistedAccountIDIsRecomputedFromCanonicalFields() throws {
        let json = """
        {
          "id": "stale-id",
          "tokenAccountID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
          "workspaceID": "wrk_ALPHA",
          "label": "Alpha",
          "createdAt": 100,
          "updatedAt": 200
        }
        """

        let account = try JSONDecoder().decode(OpenCodeWorkspaceAccount.self, from: Data(json.utf8))
        let tokenAccountID = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))

        #expect(account.id == OpenCodeWorkspaceAccount.canonicalID(
            tokenAccountID: tokenAccountID,
            workspaceID: "wrk_ALPHA"))
    }
}
