import Testing
@testable import CodexBar

struct QuotaWarningNotificationLogicTests {
    @Test
    func `quota warning copy includes current remaining and threshold`() {
        let copy = QuotaWarningNotificationLogic.notificationCopy(
            providerName: "Codex",
            window: .session,
            threshold: 20,
            currentRemaining: 12.4)

        #expect(copy.title == "Codex session quota low")
        #expect(copy.body == "12% left. Reached your 20% session warning threshold.")
    }

    @Test
    func `quota warning copy clamps current remaining`() {
        let copy = QuotaWarningNotificationLogic.notificationCopy(
            providerName: "Codex",
            window: .weekly,
            threshold: 50,
            currentRemaining: -3)

        #expect(copy.title == "Codex weekly quota low")
        #expect(copy.body == "0% left. Reached your 50% weekly warning threshold.")
    }

    @Test
    func `does nothing without crossing`() {
        let crossed = QuotaWarningNotificationLogic.crossedThreshold(
            previousRemaining: 60,
            currentRemaining: 55,
            thresholds: [50, 20],
            alreadyFired: [])

        #expect(crossed == nil)
    }

    @Test
    func `detects downward crossing`() {
        let crossed = QuotaWarningNotificationLogic.crossedThreshold(
            previousRemaining: 55,
            currentRemaining: 45,
            thresholds: [50, 20],
            alreadyFired: [])

        #expect(crossed == 50)
    }

    @Test
    func `skips already fired thresholds`() {
        let crossed = QuotaWarningNotificationLogic.crossedThreshold(
            previousRemaining: 55,
            currentRemaining: 45,
            thresholds: [50, 20],
            alreadyFired: [50])

        #expect(crossed == nil)
    }

    @Test
    func `chooses most severe threshold when crossing several at once`() {
        let crossed = QuotaWarningNotificationLogic.crossedThreshold(
            previousRemaining: 80,
            currentRemaining: 10,
            thresholds: [50, 20],
            alreadyFired: [])

        #expect(crossed == 20)
    }

    @Test
    func `startup below threshold warns once at most severe threshold`() {
        let crossed = QuotaWarningNotificationLogic.crossedThreshold(
            previousRemaining: nil,
            currentRemaining: 10,
            thresholds: [50, 20],
            alreadyFired: [])

        #expect(crossed == 20)
    }

    @Test
    func `warning marks threshold and higher thresholds fired`() {
        let fired = QuotaWarningNotificationLogic.firedThresholdsAfterWarning(
            threshold: 20,
            thresholds: [50, 20])

        #expect(fired == [50, 20])
    }

    @Test
    func `recovery clears only thresholds below current remaining`() {
        let cleared = QuotaWarningNotificationLogic.thresholdsToClear(
            currentRemaining: 30,
            alreadyFired: [50, 20])

        #expect(cleared == [20])
    }

    @Test
    func `zero threshold does not post quota warning`() {
        let crossed = QuotaWarningNotificationLogic.crossedThreshold(
            previousRemaining: 10,
            currentRemaining: 0,
            thresholds: [10, 0],
            alreadyFired: [10])

        #expect(crossed == nil)
        #expect(QuotaWarningNotificationLogic.firedThresholdsAfterWarning(threshold: 10, thresholds: [10, 0]) == [10])
    }
}
