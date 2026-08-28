import Testing
@testable import CodexBarCore

struct AntigravityLocalSnapshotSelectionTests {
    @Test
    func `selected account wins before quota richness`() throws {
        let selectedAccount = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Low",
                    modelId: "gemini-3-pro-low",
                    remainingFraction: 0.9,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: "selected@example.com",
            accountPlan: "Pro",
            source: .local)
        let richerOtherAccount = AntigravityStatusSnapshot(
            quotaSummary: AntigravityQuotaSummary(
                description: nil,
                groups: [
                    AntigravityQuotaSummaryGroup(
                        displayName: "Gemini Models",
                        description: nil,
                        buckets: [
                            AntigravityQuotaSummaryBucket(
                                bucketId: "gemini-5h",
                                displayName: "Five Hour Limit",
                                remainingFraction: 0.9,
                                resetDescription: nil,
                                disabled: false),
                        ]),
                ]),
            accountEmail: "other@example.com",
            accountPlan: "Ultra",
            source: .local)

        let selected = try #require(
            AntigravityStatusProbe.preferredLocalSnapshot(
                [richerOtherAccount, selectedAccount],
                matchingAccountEmail: " SELECTED@example.com "))

        #expect(selected.accountEmail == "selected@example.com")
    }
}
