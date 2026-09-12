import Foundation
import Testing
@testable import CodexBarCore

/// Rows whose live usage is unavailable used to project to `nil`, so the menu
/// card went blank while `cswap list` still showed numbers. These cover the
/// display-only fallback, the real measurement age, spend, and the disabled marker.
struct ClaudeSwapLastGoodProjectionTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_782_158_400)
    private let now = Date(timeIntervalSince1970: 1_782_160_000)

    private func snapshots(for row: ClaudeSwapAccountRow) -> [ProviderAccountUsageSnapshot] {
        ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(
                activeAccountNumber: row.isActive ? row.number : nil,
                accounts: [row]),
            now: self.now)
    }

    private func lastGood(
        fiveHour: Double? = nil,
        sevenDay: Double? = nil,
        spend: ClaudeSwapSpendWindow? = nil) -> ClaudeSwapLastGoodUsage
    {
        ClaudeSwapLastGoodUsage(
            measurement: ClaudeSwapUsageMeasurement(
                fiveHour: fiveHour.map { ClaudeSwapUsageWindow(usedPercent: $0, resetsAt: nil) },
                sevenDay: sevenDay.map { ClaudeSwapUsageWindow(usedPercent: $0, resetsAt: nil) },
                spend: spend),
            fetchedAt: self.fetchedAt)
    }

    @Test
    func `a token expired row keeps its last known bars instead of blanking`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .tokenExpired,
            fiveHour: nil,
            sevenDay: nil,
            lastGoodUsage: self.lastGood(fiveHour: 62, sevenDay: 41))).first)

        let snapshot = try #require(account.snapshot)
        #expect(snapshot.primary?.usedPercent == 62)
        #expect(snapshot.secondary?.usedPercent == 41)
        // The card must state the measurement's real age, not the refresh time.
        #expect(snapshot.updatedAt == self.fetchedAt)
        // The row stays non-actionable and keeps explaining why.
        #expect(account.canActivate == false)
        #expect(account.error?.contains("Token expired") == true)
    }

    @Test
    func `a row with neither live nor last known usage still projects to nil`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .noCredentials,
            fiveHour: nil,
            sevenDay: nil)).first)

        #expect(account.snapshot == nil)
    }

    @Test
    func `an ok row is dated by claude swap's own fetch time`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: 10, resetsAt: nil),
            sevenDay: nil,
            usageFetchedAt: self.fetchedAt)).first)

        #expect(account.snapshot?.updatedAt == self.fetchedAt)
    }

    @Test
    func `an ok row without freshness falls back to the refresh time`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: 10, resetsAt: nil),
            sevenDay: nil)).first)

        #expect(account.snapshot?.updatedAt == self.now)
    }

    @Test
    func `spend projects onto the shared provider cost row`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: 10, resetsAt: nil),
            sevenDay: nil,
            spend: ClaudeSwapSpendWindow(
                used: 12.5,
                limit: 50,
                usedPercent: 25,
                currencyCode: "USD",
                resetsAt: nil))).first)

        let cost = try #require(account.snapshot?.providerCost)
        #expect(cost.used == 12.5)
        #expect(cost.limit == 50)
        #expect(cost.currencyCode == "USD")
    }

    @Test
    func `an account with only spend still renders a card`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .ok,
            fiveHour: nil,
            sevenDay: nil,
            spend: ClaudeSwapSpendWindow(
                used: 1,
                limit: 10,
                usedPercent: 10,
                currencyCode: "USD",
                resetsAt: nil))).first)

        #expect(account.snapshot?.providerCost?.used == 1)
    }

    /// An `unavailable` row retains the previous snapshot when a window is still
    /// exhausted. If that previous snapshot was itself a last-known fallback, the
    /// retention must carry the provenance forward — otherwise surviving one more
    /// refresh silently promotes stale data to live and it reaches the bar icon.
    @Test
    func `retaining a last known snapshot does not promote it to live`() throws {
        let resetsAt = self.now.addingTimeInterval(3600)
        let exhausted = ClaudeSwapLastGoodUsage(
            measurement: ClaudeSwapUsageMeasurement(
                fiveHour: ClaudeSwapUsageWindow(usedPercent: 100, resetsAt: resetsAt),
                sevenDay: nil),
            fetchedAt: self.fetchedAt)

        // First pass: no live usage, so the card falls back to the last known one.
        let expired = ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .tokenExpired,
            fiveHour: nil,
            sevenDay: nil,
            lastGoodUsage: exhausted)
        let first = try #require(self.snapshots(for: expired).first)
        #expect(first.usesLastKnownUsage)

        // Second pass: claude-swap defers polling, and retention keeps that snapshot.
        let deferred = ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .unavailable,
            fiveHour: nil,
            sevenDay: nil)
        let retained = try #require(ClaudeSwapAccountProjection.accountSnapshots(
            from: ClaudeSwapAccountList(activeAccountNumber: nil, accounts: [deferred]),
            previousAccounts: [first],
            now: self.now).first)

        #expect(retained.snapshot?.primary?.usedPercent == 100)
        #expect(retained.usesLastKnownUsage, "retention must not promote a fallback to live data")
    }

    @Test
    func `a disabled account is labeled but stays selectable`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: false,
            usageStatus: .ok,
            fiveHour: ClaudeSwapUsageWindow(usedPercent: 10, resetsAt: nil),
            sevenDay: nil,
            isDisabled: true)).first)

        #expect(account.displayLabel == "a@b.c (disabled)")
        #expect(account.canActivate == true)
    }

    @Test
    func `a foreign credential row explains that a switch repairs it`() throws {
        let account = try #require(self.snapshots(for: ClaudeSwapAccountRow(
            number: 1,
            email: "a@b.c",
            isActive: true,
            usageStatus: .foreignCredential,
            fiveHour: nil,
            sevenDay: nil,
            lastGoodUsage: self.lastGood(fiveHour: 12))).first)

        #expect(account.error?.contains("different account") == true)
        #expect(account.snapshot?.primary?.usedPercent == 12)
    }
}
