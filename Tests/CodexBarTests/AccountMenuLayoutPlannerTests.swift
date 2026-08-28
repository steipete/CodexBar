import CodexBarCore
import Foundation
import Testing

/// Coverage for the compact multi-account menu plan: active card pinned first,
/// inactive accounts as headroom-sorted compact rows, healthy tail collapsed
/// behind a summary row, and per-account expansion back to full cards.
struct AccountMenuLayoutPlannerTests {
    private static let now = Date(timeIntervalSince1970: 1_782_000_000)

    private func account(
        slot: Int,
        email: String,
        isActive: Bool = false,
        canActivate: Bool = true,
        sessionUsed: Double? = nil,
        weeklyUsed: Double? = nil,
        scopedUsed: [(name: String, used: Double)] = [],
        sessionIsSyntheticPlaceholder: Bool = false,
        error: String? = nil,
        hasSnapshot: Bool = true) -> ProviderAccountUsageSnapshot
    {
        let primary = sessionUsed.map { used in
            RateWindow(
                usedPercent: used,
                windowMinutes: 300,
                resetsAt: Self.now.addingTimeInterval(3600),
                resetDescription: nil,
                isSyntheticPlaceholder: sessionIsSyntheticPlaceholder)
        }
        let secondary = weeklyUsed.map { used in
            RateWindow(
                usedPercent: used,
                windowMinutes: 7 * 24 * 60,
                resetsAt: Self.now.addingTimeInterval(86400),
                resetDescription: nil)
        }
        let extras = scopedUsed.map { scoped in
            NamedRateWindow(
                id: "claude-weekly-scoped-\(scoped.name.lowercased())",
                title: "\(scoped.name) only",
                window: RateWindow(
                    usedPercent: scoped.used,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: Self.now.addingTimeInterval(86400),
                    resetDescription: nil))
        }
        let snapshot: UsageSnapshot? = hasSnapshot
            ? UsageSnapshot(
                primary: primary,
                secondary: secondary,
                extraRateWindows: extras.isEmpty ? nil : extras,
                updatedAt: Self.now,
                identity: nil)
            : nil
        return ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: String(slot)),
            provider: .claude,
            displayLabel: email,
            isActive: isActive,
            canActivate: canActivate,
            snapshot: snapshot,
            error: error,
            sourceLabel: "claude-swap")
    }

    /// Six accounts mirroring the motivating screenshot: one active, one badly
    /// constrained, the rest healthy.
    private func screenshotFixture() -> [ProviderAccountUsageSnapshot] {
        [
            self.account(slot: 1, email: "alice@example.com", isActive: true, sessionUsed: 4, weeklyUsed: 1),
            self.account(slot: 2, email: "work@example.com", sessionUsed: 3, weeklyUsed: 0, scopedUsed: [("Fable", 3)]),
            self.account(slot: 3, email: "spare@example.com", sessionUsed: 0, weeklyUsed: 0),
            self.account(slot: 4, email: "team@example.com", weeklyUsed: 4, scopedUsed: [("Fable", 8)]),
            self.account(
                slot: 5,
                email: "burner@example.com",
                sessionUsed: 0,
                weeklyUsed: 57,
                scopedUsed: [("Fable", 100)]),
            self.account(slot: 6, email: "backup@example.com", sessionUsed: 0, weeklyUsed: 2),
        ]
    }

    private func compactRows(in plan: AccountMenuLayoutPlanner.Plan) -> [AccountMenuLayoutPlanner.CompactRow] {
        plan.rows.compactMap { row in
            if case let .compact(compact) = row { return compact }
            return nil
        }
    }

    @Test
    func `fewer than four accounts keeps stacked cards`() {
        let accounts = [
            self.account(slot: 1, email: "a@example.com", isActive: true, sessionUsed: 10),
            self.account(slot: 2, email: "b@example.com", sessionUsed: 20),
            self.account(slot: 3, email: "c@example.com", sessionUsed: 30),
        ]

        let plan = AccountMenuLayoutPlanner.plan(accounts: accounts)

        #expect(!plan.usesCompactLayout)
        #expect(plan.rows == accounts.map { .card($0.id) })
    }

    @Test
    func `active card first then constrained rows then best candidate then collapsed tail`() {
        let plan = AccountMenuLayoutPlanner.plan(accounts: self.screenshotFixture())

        #expect(plan.usesCompactLayout)
        guard case let .card(first) = plan.rows.first else {
            Issue.record("expected active card first, got \(plan.rows)")
            return
        }
        #expect(first.opaqueID == "1")

        let compacts = self.compactRows(in: plan)
        #expect(compacts.map(\.label) == ["burner@example.com", "spare@example.com"])

        let constrained = compacts[0]
        #expect(constrained.headroomPercent == 0)
        #expect(constrained.severity == .critical)
        #expect(constrained.constraintDetail == "Fable 0% · Weekly 43%")
        #expect(!constrained.isBestCandidate)

        let best = compacts[1]
        #expect(best.severity == .healthy)
        #expect(best.isBestCandidate)
        #expect(best.constraintDetail == nil)

        #expect(plan.rows.last == .collapsedHealthy(count: 3))
    }

    @Test
    func `expanded account renders as card in its sorted position`() {
        let accounts = self.screenshotFixture()
        let constrained = accounts[4].id

        let plan = AccountMenuLayoutPlanner.plan(accounts: accounts, expandedAccountIDs: [constrained])

        #expect(plan.rows[0] == .card(accounts[0].id))
        #expect(plan.rows[1] == .card(constrained))
        let compacts = self.compactRows(in: plan)
        #expect(compacts.map(\.label) == ["spare@example.com"])
        #expect(plan.rows.last == .collapsedHealthy(count: 3))
    }

    @Test
    func `expanded healthy tail lists every account sorted by headroom`() {
        let plan = AccountMenuLayoutPlanner.plan(accounts: self.screenshotFixture(), healthyTailExpanded: true)

        let compacts = self.compactRows(in: plan)
        #expect(compacts.map(\.label) == [
            "burner@example.com",
            "team@example.com",
            "work@example.com",
            "backup@example.com",
            "spare@example.com",
        ])
        #expect(!plan.rows.contains { row in
            if case .collapsedHealthy = row { return true }
            return false
        })
    }

    @Test
    func `error account without snapshot sorts with the constrained rows`() {
        var accounts = self.screenshotFixture()
        accounts[3] = self.account(
            slot: 4,
            email: "team@example.com",
            canActivate: false,
            error: "Token expired.",
            hasSnapshot: false)

        let plan = AccountMenuLayoutPlanner.plan(accounts: accounts)

        let compacts = self.compactRows(in: plan)
        let errorRow = compacts.first { $0.label == "team@example.com" }
        #expect(errorRow != nil)
        #expect(errorRow?.hasError == true)
        #expect(errorRow?.headroomPercent == nil)
        #expect(errorRow?.severity == nil)
        // Unknown headroom sorts alongside the critical rows, never into the healthy tail.
        #expect(plan.rows.last == .collapsedHealthy(count: 2))
    }

    @Test
    func `best candidate requires activation support`() {
        var accounts = self.screenshotFixture()
        accounts[2] = self.account(
            slot: 3,
            email: "spare@example.com",
            canActivate: false,
            sessionUsed: 0,
            weeklyUsed: 0)

        let plan = AccountMenuLayoutPlanner.plan(accounts: accounts)

        let best = self.compactRows(in: plan).filter(\.isBestCandidate)
        #expect(best.map(\.label) == ["backup@example.com"])
    }

    @Test
    func `synthetic session placeholder does not count toward headroom`() {
        let account = self.account(
            slot: 9,
            email: "placeholder@example.com",
            sessionUsed: 100,
            weeklyUsed: 20,
            sessionIsSyntheticPlaceholder: true)

        #expect(AccountMenuLayoutPlanner.headroomPercent(for: account) == 80)
    }

    @Test
    func `collapse only engages once enough healthy rows exist`() {
        let accounts = [
            self.account(slot: 1, email: "a@example.com", isActive: true, sessionUsed: 5),
            self.account(slot: 2, email: "b@example.com", sessionUsed: 95),
            self.account(slot: 3, email: "c@example.com", sessionUsed: 60),
            self.account(slot: 4, email: "d@example.com", sessionUsed: 10),
        ]

        let plan = AccountMenuLayoutPlanner.plan(accounts: accounts)

        // Healthy rows: only "d" (90% headroom, best candidate) — nothing left to fold.
        #expect(!plan.rows.contains { row in
            if case .collapsedHealthy = row { return true }
            return false
        })
        let compacts = self.compactRows(in: plan)
        #expect(compacts.map(\.label) == ["b@example.com", "c@example.com", "d@example.com"])
    }

    @Test
    func `scoped window titles drop the only suffix`() {
        #expect(AccountMenuLayoutPlanner.shortLabel(forWindowTitle: "Fable only") == "Fable")
        #expect(AccountMenuLayoutPlanner.shortLabel(forWindowTitle: "Weekly") == "Weekly")
        #expect(AccountMenuLayoutPlanner.shortLabel(forWindowTitle: " only") == " only")
    }
}
