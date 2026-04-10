import Foundation
import Testing
@testable import CodexBarCore

struct OpenAIDashboardFetcherCreditsWaitTests {
    @Test
    func `waits after scroll request`() {
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
    func `waits briefly when header visible but table empty`() {
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
    func `stops waiting after header has been visible long enough`() {
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
    func `waits briefly after first dashboard signal even when header not present yet`() {
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
    func `stops waiting eventually when header never appears`() {
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
    func `probe waits briefly after reaching usage route without email or dashboard signals`() {
        let now = Date()
        let shouldWait = OpenAIDashboardFetcher.shouldWaitForProbeReadiness(.init(
            now: now,
            usageRouteSeenAt: now.addingTimeInterval(-1.0),
            dashboardSignalSeenAt: nil,
            signedInEmail: nil,
            hasDashboardSignal: false))
        #expect(shouldWait == true)
    }

    @Test
    func `probe waits briefly for email after dashboard signals appear`() {
        let now = Date()
        let shouldWait = OpenAIDashboardFetcher.shouldWaitForProbeReadiness(.init(
            now: now,
            usageRouteSeenAt: now.addingTimeInterval(-3.0),
            dashboardSignalSeenAt: now.addingTimeInterval(-1.0),
            signedInEmail: nil,
            hasDashboardSignal: true))
        #expect(shouldWait == true)
    }

    @Test
    func `probe stops waiting once signed in email is available`() {
        let now = Date()
        let shouldWait = OpenAIDashboardFetcher.shouldWaitForProbeReadiness(.init(
            now: now,
            usageRouteSeenAt: now.addingTimeInterval(-0.2),
            dashboardSignalSeenAt: now.addingTimeInterval(-0.2),
            signedInEmail: "user@example.com",
            hasDashboardSignal: true))
        #expect(shouldWait == false)
    }

    @Test
    func `probe grace restarts after route reload resets readiness timestamps`() {
        let now = Date()
        let shouldWait = OpenAIDashboardFetcher.shouldWaitForProbeReadiness(.init(
            now: now,
            usageRouteSeenAt: now,
            dashboardSignalSeenAt: nil,
            signedInEmail: nil,
            hasDashboardSignal: false))
        #expect(shouldWait == true)
    }

    @Test
    func `sanitized timeout preserves positive caller deadline`() {
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(60) == 60)
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(25) == 25)
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(0.5) == 0.5)
    }

    @Test
    func `sanitized timeout falls back for invalid values`() {
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(0) == 1)
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(-5) == 1)
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(.infinity) == 1)
        #expect(OpenAIDashboardFetcher.sanitizedTimeout(.nan) == 1)
    }

    @Test
    func `deadline starts at call start and remaining timeout shrinks from there`() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let deadline = OpenAIDashboardFetcher.deadline(startingAt: start, timeout: 15)

        #expect(deadline.timeIntervalSince(start) == 15)

        let remaining = OpenAIDashboardFetcher.remainingTimeout(
            until: deadline,
            now: start.addingTimeInterval(14.5))
        #expect(remaining == 0.5)
    }

    @Test
    func `remaining timeout does not go negative`() {
        let deadline = Date(timeIntervalSinceReferenceDate: 2000)
        let remaining = OpenAIDashboardFetcher.remainingTimeout(
            until: deadline,
            now: deadline.addingTimeInterval(3))
        #expect(remaining == 0)
    }

    @Test
    func `usage route matcher accepts legacy settings route`() {
        #expect(OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/codex/settings/usage"))
    }

    @Test
    func `usage route matcher accepts cloud settings route`() {
        #expect(OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/codex/cloud/settings/usage"))
    }

    @Test
    func `usage route matcher accepts trailing slash variants`() {
        #expect(OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/codex/settings/usage/"))
        #expect(OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/codex/cloud/settings/usage/"))
    }

    @Test
    func `usage route matcher rejects unrelated routes`() {
        #expect(!OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/"))
        #expect(!OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/codex"))
        #expect(!OpenAIDashboardFetcher.isUsageRoute(nil))
    }
}
