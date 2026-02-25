import Testing
@testable import CodexBar

@Suite
struct QuotaWarningNotificationLogicTests {
    @Test
    func doesNothingWithoutPreviousValue() {
        let crossed = QuotaWarningNotificationLogic.crossedThresholds(
            previousRemaining: nil, currentRemaining: 40,
            thresholds: [80, 50, 20], alreadyFired: [])
        #expect(crossed.isEmpty)
    }

    @Test
    func detectsSingleThresholdCrossing() {
        let crossed = QuotaWarningNotificationLogic.crossedThresholds(
            previousRemaining: 55, currentRemaining: 45,
            thresholds: [80, 50, 20], alreadyFired: [])
        #expect(crossed == [50])
    }

    @Test
    func detectsMultipleThresholdCrossings() {
        let crossed = QuotaWarningNotificationLogic.crossedThresholds(
            previousRemaining: 55, currentRemaining: 15,
            thresholds: [80, 50, 20], alreadyFired: [])
        #expect(crossed == [50, 20])
    }

    @Test
    func doesNotRefireAlreadyFiredThreshold() {
        let crossed = QuotaWarningNotificationLogic.crossedThresholds(
            previousRemaining: 55, currentRemaining: 45,
            thresholds: [80, 50, 20], alreadyFired: [50])
        #expect(crossed.isEmpty)
    }

    @Test
    func clearsRestoredThresholds() {
        let restored = QuotaWarningNotificationLogic.restoredThresholds(
            currentRemaining: 60, alreadyFired: [80, 50, 20])
        #expect(restored == [50, 20])
    }

    @Test
    func doesNotCrossOnUpwardMovement() {
        let crossed = QuotaWarningNotificationLogic.crossedThresholds(
            previousRemaining: 45, currentRemaining: 55,
            thresholds: [80, 50, 20], alreadyFired: [])
        #expect(crossed.isEmpty)
    }

    @Test
    func handlesExactThresholdBoundary() {
        let crossed = QuotaWarningNotificationLogic.crossedThresholds(
            previousRemaining: 50.001, currentRemaining: 50.0,
            thresholds: [80, 50, 20], alreadyFired: [])
        #expect(crossed == [50])
    }

    @Test
    func handlesEmptyThresholds() {
        let crossed = QuotaWarningNotificationLogic.crossedThresholds(
            previousRemaining: 80, currentRemaining: 10,
            thresholds: [], alreadyFired: [])
        #expect(crossed.isEmpty)
    }

    @Test
    func doesNotCrossWhenStayingAboveThreshold() {
        let crossed = QuotaWarningNotificationLogic.crossedThresholds(
            previousRemaining: 90, currentRemaining: 85,
            thresholds: [80, 50, 20], alreadyFired: [])
        #expect(crossed.isEmpty)
    }

    @Test
    func doesNotRestoreThresholdAboveCurrentRemaining() {
        let restored = QuotaWarningNotificationLogic.restoredThresholds(
            currentRemaining: 60, alreadyFired: [80, 50, 20])
        #expect(!restored.contains(80))
        #expect(restored.contains(50))
        #expect(restored.contains(20))
    }

    @Test
    func crossesAllThresholdsOnLargeDrop() {
        let crossed = QuotaWarningNotificationLogic.crossedThresholds(
            previousRemaining: 100, currentRemaining: 5,
            thresholds: [80, 50, 20], alreadyFired: [])
        #expect(crossed == [80, 50, 20])
    }
}
