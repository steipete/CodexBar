import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct OpenAIDashboardFetcherCreditsWaitTests {
    @Test
    func waitsAfterScrollRequest() {
        let now = Date()
        let shouldWait = OpenAIDashboardFetcher.shouldWaitForCreditsHistory(.init(
            now: now,
            anyDashboardSignalAt: now.addingTimeInterval(-10),
            creditsHeaderVisibleAt: nil,
            creditsHeaderPresent: false,
            creditsHeaderInViewport: false,
            didScrollToCredits: true))
        #expect(shouldWait == true)
    }

    @Test
    func waitsBrieflyWhenHeaderVisibleButTableEmpty() {
        let now = Date()
        let visibleAt = now.addingTimeInterval(-1.0)
        let shouldWait = OpenAIDashboardFetcher.shouldWaitForCreditsHistory(.init(
            now: now,
            anyDashboardSignalAt: now.addingTimeInterval(-10),
            creditsHeaderVisibleAt: visibleAt,
            creditsHeaderPresent: true,
            creditsHeaderInViewport: true,
            didScrollToCredits: false))
        #expect(shouldWait == true)
    }

    @Test
    func stopsWaitingAfterHeaderHasBeenVisibleLongEnough() {
        let now = Date()
        let visibleAt = now.addingTimeInterval(-3.0)
        let shouldWait = OpenAIDashboardFetcher.shouldWaitForCreditsHistory(.init(
            now: now,
            anyDashboardSignalAt: now.addingTimeInterval(-10),
            creditsHeaderVisibleAt: visibleAt,
            creditsHeaderPresent: true,
            creditsHeaderInViewport: true,
            didScrollToCredits: false))
        #expect(shouldWait == false)
    }

    @Test
    func waitsBrieflyAfterFirstDashboardSignalEvenWhenHeaderNotPresentYet() {
        let now = Date()
        let startedAt = now.addingTimeInterval(-2.0)
        let shouldWait = OpenAIDashboardFetcher.shouldWaitForCreditsHistory(.init(
            now: now,
            anyDashboardSignalAt: startedAt,
            creditsHeaderVisibleAt: nil,
            creditsHeaderPresent: false,
            creditsHeaderInViewport: false,
            didScrollToCredits: false))
        #expect(shouldWait == true)
    }

    @Test
    func stopsWaitingEventuallyWhenHeaderNeverAppears() {
        let now = Date()
        let startedAt = now.addingTimeInterval(-7.0)
        let shouldWait = OpenAIDashboardFetcher.shouldWaitForCreditsHistory(.init(
            now: now,
            anyDashboardSignalAt: startedAt,
            creditsHeaderVisibleAt: nil,
            creditsHeaderPresent: false,
            creditsHeaderInViewport: false,
            didScrollToCredits: false))
        #expect(shouldWait == false)
    }

    @Test
    func sanitizedTimeoutPreservesPositiveCallerDeadline() {
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(60) == 60)
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(25) == 25)
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(0.5) == 0.5)
    }

    @Test
    func sanitizedTimeoutFallsBackForInvalidValues() {
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(0) == 1)
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(-5) == 1)
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(.infinity) == 1)
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(.nan) == 1)
    }

    @Test
    func deadlineStartsAtCallStartAndRemainingTimeoutShrinksFromThere() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let deadline = OpenAIDashboardFetcher.deadline(startingAt: start, timeout: 15)

        #expect(deadline.timeIntervalSince(start) == 15)

        let remaining = OpenAIDashboardFetcher.remainingTimeout(
            until: deadline,
            now: start.addingTimeInterval(14.5))
        #expect(remaining == 0.5)
    }

    @Test
    func remainingTimeoutDoesNotGoNegative() {
        let deadline = Date(timeIntervalSinceReferenceDate: 2000)
        let remaining = OpenAIDashboardFetcher.remainingTimeout(
            until: deadline,
            now: deadline.addingTimeInterval(3))
        #expect(remaining == 0)
    }
}
