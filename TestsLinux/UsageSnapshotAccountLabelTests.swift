import CodexBarCore
import Foundation
import Testing

struct UsageSnapshotAccountLabelTests {
    @Test(arguments: [
        (nil as String?, "Team Account"),
        ("", "Team Account"),
        (" \n ", "Team Account"),
        (" fetched@example.com ", "fetched@example.com"),
    ])
    func `fallback label preserves the provider identity`(email: String?, expected: String) {
        let snapshot = self.snapshot(email: email)

        let labeled = snapshot.withAccountLabel(" Team Account ", for: .zai)

        #expect(labeled.identity?.accountEmail == expected)
        #expect(labeled.identity?.accountID == "fixture-account-id")
        #expect(labeled.identity?.accountOrganization == "Fixture Organization")
        #expect(labeled.identity?.loginMethod == "Fixture Plan")
        #expect(labeled.primary?.usedPercent == 25)
        #expect(labeled.updatedAt == snapshot.updatedAt)
    }

    @Test(arguments: ["", " \n "])
    func `empty labels leave the original identity untouched`(label: String) {
        let labeled = self.snapshot(email: " fetched@example.com ").withAccountLabel(label, for: .zai)

        #expect(labeled.identity?.accountEmail == " fetched@example.com ")
        #expect(labeled.identity?.accountID == "fixture-account-id")
    }

    @Test
    func `fallback labels never borrow another provider identity`() {
        let labeled = self.snapshot(email: "fetched@example.com").withAccountLabel("Other Account", for: .synthetic)

        #expect(labeled.identity?.providerID == .synthetic)
        #expect(labeled.identity?.accountEmail == "Other Account")
        #expect(labeled.identity?.accountID == nil)
        #expect(labeled.identity?.accountOrganization == nil)
        #expect(labeled.identity?.loginMethod == nil)
    }

    private func snapshot(email: String?) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .zai,
                accountEmail: email,
                accountOrganization: "Fixture Organization",
                loginMethod: "Fixture Plan",
                accountID: "fixture-account-id"))
    }
}
