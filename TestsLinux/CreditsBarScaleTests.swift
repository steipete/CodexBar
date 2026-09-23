import CodexBarCore
import Foundation
import Testing

struct CreditsBarScaleTests {
    @Test
    func `balances at or below 1000 keep the historical 1k scale`() {
        #expect(CreditsBarScale.autoScale(for: 0) == 1000)
        #expect(CreditsBarScale.autoScale(for: 500) == 1000)
        #expect(CreditsBarScale.autoScale(for: 1000) == 1000)
        #expect(CreditsBarScale.remainingPercent(remaining: 0) == 0)
        #expect(CreditsBarScale.remainingPercent(remaining: 500) == 50)
        #expect(CreditsBarScale.remainingPercent(remaining: 1000) == 100)
    }

    @Test
    func `balances above 1000 use the next thousand bucket instead of clamping to 100 percent`() {
        #expect(CreditsBarScale.autoScale(for: 1000.01) == 2000)
        #expect(CreditsBarScale.autoScale(for: 1999) == 2000)
        #expect(CreditsBarScale.autoScale(for: 2000) == 2000)
        #expect(CreditsBarScale.autoScale(for: 2001) == 3000)
        #expect(CreditsBarScale.autoScale(for: 2263.27) == 3000)
        #expect(CreditsBarScale.remainingPercent(remaining: 2263.27) == 2263.27 / 3000 * 100)
        #expect(CreditsBarScale.remainingPercent(remaining: 2263.27) < 100)
        #expect(CreditsBarScale.remainingPercent(remaining: 2263.27) > CreditsBarScale
            .remainingPercent(remaining: 1500))
    }

    @Test
    func `stateless auto scale refills at thousand-credit boundaries`() {
        #expect(CreditsBarScale.remainingPercent(remaining: 2001) == 2001 / 3000.0 * 100)
        #expect(CreditsBarScale.remainingPercent(remaining: 2000) == 100)
        #expect(CreditsBarScale.remainingPercent(remaining: 1001) == 1001 / 2000.0 * 100)
        #expect(CreditsBarScale.remainingPercent(remaining: 1000) == 100)
    }

    @Test
    func `session high water keeps auto scale stable while credits deplete`() {
        let store = CreditsBarScale.HighWater()
        let first = CreditsBarScale.display(from: Self.credits(2001), highWater: store)
        let second = CreditsBarScale.display(from: Self.credits(2000), highWater: store)

        #expect(first?.scale == 3000)
        #expect(second?.scale == 3000)
        #expect(first?.remainingPercent == 2001 / 3000.0 * 100)
        #expect(second?.remainingPercent == 2000 / 3000.0 * 100)
        #expect((second?.remainingPercent ?? 100) < (first?.remainingPercent ?? 0))

        let crossingFloor = CreditsBarScale.HighWater()
        let aboveFloor = CreditsBarScale.display(from: Self.credits(1001), highWater: crossingFloor)
        let atFloor = CreditsBarScale.display(from: Self.credits(1000), highWater: crossingFloor)

        #expect(aboveFloor?.scale == 2000)
        #expect(atFloor?.scale == 2000)
        #expect(atFloor?.remainingPercent == 50)
        #expect((atFloor?.remainingPercent ?? 100) < (aboveFloor?.remainingPercent ?? 0))
    }

    @Test
    func `a purchase raises the session high water`() {
        let store = CreditsBarScale.HighWater()
        #expect(CreditsBarScale.display(from: Self.credits(500), highWater: store)?.scale == 1000)
        #expect(CreditsBarScale.display(from: Self.credits(2263.27), highWater: store)?.scale == 3000)
        #expect(CreditsBarScale.display(from: Self.credits(1800), highWater: store)?.scale == 3000)
        #expect(CreditsBarScale.display(from: Self.credits(1800), highWater: store)?.remainingPercent == 1800 / 3000.0
            * 100)
    }

    @Test
    func `selected account identity isolates session high water when switching accounts`() {
        let store = CreditsBarScale.HighWater()
        let accountA = Self.account("acct-a", email: "a@example.com")
        let accountB = Self.account("acct-b", email: "b@example.com")

        CreditsBarScale.$highWater.withValue(store) {
            CreditsBarScale.$account.withValue(accountA) {
                #expect(CreditsBarScale.sessionScale(for: 2500) == 3000)
                #expect(CreditsBarScale.display(from: Self.credits(2500))?.scale == 3000)
                #expect(CreditsBarScale.display(from: Self.credits(2500))?.remainingPercent == 2500 / 3000.0 * 100)
            }

            store.invalidateSelection(from: accountA, to: accountB)

            CreditsBarScale.$account.withValue(accountB) {
                let display = CreditsBarScale.display(from: Self.credits(500))
                #expect(CreditsBarScale.sessionScale(for: 500) == 1000)
                #expect(display?.scale == 1000)
                #expect(display?.remainingPercent == 50)
            }

            CreditsBarScale.$account.withValue(accountA) {
                #expect(CreditsBarScale.sessionScale(for: 2000) == 3000)
                #expect(CreditsBarScale.display(from: Self.credits(2000))?.remainingPercent == 2000 / 3000.0 * 100)
            }
        }
    }

    @Test
    func `descending boundaries stay stable per selected account after a switch`() {
        let store = CreditsBarScale.HighWater()
        let accountA = Self.account("acct-a", email: "a@example.com")
        let accountB = Self.account("acct-b", email: "b@example.com")

        let aHigh = CreditsBarScale.display(from: Self.credits(2001), highWater: store, account: accountA)
        let aLow = CreditsBarScale.display(from: Self.credits(2000), highWater: store, account: accountA)
        store.invalidateSelection(from: accountA, to: accountB)
        let bHigh = CreditsBarScale.display(from: Self.credits(1001), highWater: store, account: accountB)
        let bLow = CreditsBarScale.display(from: Self.credits(1000), highWater: store, account: accountB)
        let aAfterSwitch = CreditsBarScale.display(from: Self.credits(1000), highWater: store, account: accountA)

        #expect(aHigh?.scale == 3000)
        #expect(aLow?.scale == 3000)
        #expect((aLow?.remainingPercent ?? 100) < (aHigh?.remainingPercent ?? 0))
        #expect(bHigh?.scale == 2000)
        #expect(bLow?.scale == 2000)
        #expect(bLow?.remainingPercent == 50)
        #expect((bLow?.remainingPercent ?? 100) < (bHigh?.remainingPercent ?? 0))
        #expect(aAfterSwitch?.scale == 3000)
        #expect(aAfterSwitch?.remainingPercent == 1000 / 3000.0 * 100)
    }

    @Test
    func `indistinguishable account switches drop the shared high water`() {
        let store = CreditsBarScale.HighWater()
        #expect(store.observe(remaining: 2500, account: .unresolved) == 3000)
        store.invalidateSelection(from: .unresolved, to: .unresolved)
        #expect(store.observe(remaining: 500, account: .unresolved) == 1000)
    }

    @Test
    func `provider account identity is preferred over email for the scale key`() {
        let first = CreditsBarScale.Account(accountID: "acct-a", email: "shared@example.com")
        let second = CreditsBarScale.Account(accountID: "acct-b", email: "shared@example.com")
        let emailOnly = CreditsBarScale.Account(accountID: nil, email: "shared@example.com")

        #expect(first.key != second.key)
        #expect(first.key.hasPrefix("codex.account."))
        #expect(emailOnly.key.hasPrefix("codex.email."))
        #expect(CreditsBarScale.Account().key == CreditsBarScale.HighWater.defaultAccountKey)
    }

    @Test
    func `a positive server limit wins over the auto bucket`() {
        let now = Date()
        let credits = CreditsSnapshot(
            remaining: 2263.27,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 200,
                limit: 4000,
                remainingPercent: 95,
                resetsAt: nil,
                updatedAt: now))
        let display = CreditsBarScale.display(from: credits)

        #expect(display?.scale == 4000)
        #expect(display?.remainingPercent == 95)
        #expect(CreditsBarScale.remainingPercent(remaining: 2263.27, limit: 4000) == 2263.27 / 4000 * 100)
    }

    @Test
    func `a reported limit wins even after auto high water is raised`() {
        let store = CreditsBarScale.HighWater()
        #expect(store.observe(remaining: 5000) == 5000)
        let now = Date()
        let credits = CreditsSnapshot(
            remaining: 2263.27,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 200,
                limit: 4000,
                remainingPercent: 95,
                resetsAt: nil,
                updatedAt: now))

        let display = CreditsBarScale.display(from: credits, highWater: store)
        #expect(display?.scale == 4000)
        #expect(display?.remainingPercent == 95)
    }

    @Test
    func `purchased extra credits without a pack limit use auto scale`() {
        let credits = CreditsSnapshot(remaining: 2263.27, events: [], updatedAt: Date())
        let display = CreditsBarScale.display(from: credits)

        #expect(display?.scale == 3000)
        #expect(display?.remainingPercent == 2263.27 / 3000 * 100)
    }

    @Test
    func `workspace balances omit the invented credits bar scale`() {
        let credits = CreditsSnapshot(
            remaining: 2263.27,
            events: [],
            updatedAt: Date(),
            creditsAvailable: true,
            balanceIsWorkspace: true)

        #expect(CreditsBarScale.display(from: credits) == nil)
        #expect(CreditsBarScale.display(from: credits, highWater: CreditsBarScale.HighWater()) == nil)
    }

    @Test
    func `nonfinite remaining does not invent a full bar`() {
        #expect(CreditsBarScale.autoScale(for: .nan) == 1000)
        #expect(CreditsBarScale.autoScale(for: .infinity) == 1000)
        #expect(CreditsBarScale.remainingPercent(remaining: .nan) == 0)
        #expect(CreditsBarScale.remainingPercent(remaining: -.infinity) == 0)
        #expect(CreditsBarScale.remainingPercent(remaining: 50, limit: 0) == 5)
        #expect(CreditsBarScale.remainingPercent(remaining: 50, limit: -10) == 5)
    }

    private static func credits(_ remaining: Double) -> CreditsSnapshot {
        CreditsSnapshot(remaining: remaining, events: [], updatedAt: Date())
    }

    private static func account(_ accountID: String, email: String) -> CreditsBarScale.Account {
        CreditsBarScale.Account(accountID: accountID, email: email)
    }
}
