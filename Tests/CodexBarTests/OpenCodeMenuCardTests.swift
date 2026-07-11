import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct OpenCodeMenuCardTests {
    @Test
    func testWorkspaceMenuEntriesUseOwnerLabelsWithoutCredentialData() throws {
        let tokenAccountID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let alpha = try #require(OpenCodeWorkspaceAccount(
            tokenAccountID: tokenAccountID,
            workspaceID: "wrk_ALPHA",
            label: "Alpha",
            ownerLabel: "Alice"))
        let beta = try #require(OpenCodeWorkspaceAccount(
            tokenAccountID: tokenAccountID,
            workspaceID: "wrk_BETA",
            label: "Beta",
            ownerLabel: "Bob"))

        let display = TokenAccountMenuDisplay.openCode(
            accounts: OpenCodeWorkspaceAccounts(accounts: [alpha, beta], activeID: beta.id))

        #expect(display.entries.map(\.title) == ["Alpha · Alice", "Beta · Bob"])
        #expect(display.entries.map(\.id) == [alpha.id, beta.id])
        #expect(display.entries.allSatisfy { !$0.title.contains("auth=") })
        #expect(display.activeIndex == 1)
    }
}
