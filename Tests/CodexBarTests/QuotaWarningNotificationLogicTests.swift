import Testing
@testable import CodexBar

struct QuotaWarningNotificationLogicTests {
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
}
