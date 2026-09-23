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
        #expect(CreditsBarScale.autoScale(for: 2263.27) == 3000)
        #expect(CreditsBarScale.remainingPercent(remaining: 2263.27) == 2263.27 / 3000 * 100)
        #expect(CreditsBarScale.remainingPercent(remaining: 2263.27) < 100)
        #expect(CreditsBarScale.remainingPercent(remaining: 2263.27) > CreditsBarScale
            .remainingPercent(remaining: 1500))
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
}
