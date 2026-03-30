import CodexBarCore
import Foundation
import Testing

struct ResetWarningTests {
    private static func makeWindow(
        usedPercent: Double,
        windowMinutes: Int? = 300,
        resetsAt: Date?) -> RateWindow
    {
        RateWindow(usedPercent: usedPercent, windowMinutes: windowMinutes, resetsAt: resetsAt, resetDescription: nil)
    }

    @Test("no warning when resetsAt is nil")
    func noWarningWithoutResetTime() {
        let window = Self.makeWindow(usedPercent: 10, resetsAt: nil)
        let result = ResetWarningEvaluator.evaluate(
            provider: .claude,
            window: window,
            windowKind: .session,
            warningHours: 8)
        #expect(result == nil)
    }

    @Test("no warning when reset is far in the future")
    func noWarningWhenResetFarAway() {
        let future = Date().addingTimeInterval(48 * 3600)
        let window = Self.makeWindow(usedPercent: 10, resetsAt: future)
        let result = ResetWarningEvaluator.evaluate(
            provider: .claude,
            window: window,
            windowKind: .session,
            warningHours: 8)
        #expect(result == nil)
    }

    @Test("no warning when remaining is below threshold")
    func noWarningWhenLowRemaining() {
        let soon = Date().addingTimeInterval(2 * 3600)
        let window = Self.makeWindow(usedPercent: 95, resetsAt: soon)
        let result = ResetWarningEvaluator.evaluate(
            provider: .claude,
            window: window,
            windowKind: .session,
            warningHours: 8)
        #expect(result == nil)
    }

    @Test("warning fires when within window and high remaining")
    func warningWhenWithinWindowAndHighRemaining() {
        let soon = Date().addingTimeInterval(3 * 3600)
        let window = Self.makeWindow(usedPercent: 10, resetsAt: soon)
        let result = ResetWarningEvaluator.evaluate(
            provider: .claude,
            window: window,
            windowKind: .session,
            warningHours: 8)
        #expect(result != nil)
        #expect(result?.remainingPercent == 90)
        #expect(result?.providerID == .claude)
        #expect(result?.windowKind == .session)
    }

    @Test("warning fires at boundary of warning hours")
    func warningAtExactBoundary() {
        let boundary = Date().addingTimeInterval(8 * 3600)
        let window = Self.makeWindow(usedPercent: 30, resetsAt: boundary)
        let result = ResetWarningEvaluator.evaluate(
            provider: .claude,
            window: window,
            windowKind: .weekly,
            warningHours: 8)
        #expect(result != nil)
        #expect(result?.remainingPercent == 70)
    }

    @Test("no warning when past reset time")
    func noWarningWhenPastReset() {
        let past = Date().addingTimeInterval(-1 * 3600)
        let window = Self.makeWindow(usedPercent: 10, resetsAt: past)
        let result = ResetWarningEvaluator.evaluate(
            provider: .claude,
            window: window,
            windowKind: .session,
            warningHours: 8)
        #expect(result == nil)
    }

    @Test("shouldNotify returns true when no previous notification")
    func shouldNotifyFirstTime() {
        let warning = ResetWarning(
            providerID: .claude,
            windowKind: .session,
            remainingPercent: 80,
            resetsAt: Date().addingTimeInterval(3 * 3600),
            hoursUntilReset: 3)
        #expect(ResetWarningEvaluator.shouldNotify(warning: warning, lastNotifiedAt: nil))
    }

    @Test("shouldNotify returns false within cooldown")
    func shouldNotNotifyWithinCooldown() {
        let warning = ResetWarning(
            providerID: .claude,
            windowKind: .session,
            remainingPercent: 80,
            resetsAt: Date().addingTimeInterval(3 * 3600),
            hoursUntilReset: 3)
        let recent = Date().addingTimeInterval(-30 * 60)
        #expect(!ResetWarningEvaluator.shouldNotify(warning: warning, lastNotifiedAt: recent))
    }

    @Test("shouldNotify returns true after cooldown expires")
    func shouldNotifyAfterCooldown() {
        let warning = ResetWarning(
            providerID: .claude,
            windowKind: .session,
            remainingPercent: 80,
            resetsAt: Date().addingTimeInterval(3 * 3600),
            hoursUntilReset: 3)
        let old = Date().addingTimeInterval(-2 * 3600)
        #expect(ResetWarningEvaluator.shouldNotify(warning: warning, lastNotifiedAt: old))
    }

    @Test("minimum remaining percent boundary")
    func exactlyAtMinimumRemaining() {
        let soon = Date().addingTimeInterval(3 * 3600)
        let window = Self.makeWindow(usedPercent: 80, resetsAt: soon)
        let result = ResetWarningEvaluator.evaluate(
            provider: .claude,
            window: window,
            windowKind: .session,
            warningHours: 8,
            minimumRemainingPercent: 20)
        #expect(result != nil)
    }

    @Test("below minimum remaining percent")
    func belowMinimumRemaining() {
        let soon = Date().addingTimeInterval(3 * 3600)
        let window = Self.makeWindow(usedPercent: 81, resetsAt: soon)
        let result = ResetWarningEvaluator.evaluate(
            provider: .claude,
            window: window,
            windowKind: .session,
            warningHours: 8,
            minimumRemainingPercent: 20)
        #expect(result == nil)
    }
}
