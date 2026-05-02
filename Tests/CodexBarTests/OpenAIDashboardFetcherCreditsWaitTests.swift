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
    func `usage breakdown recovery waits briefly after chart classification error`() {
        let now = Date()
        let shouldWait = OpenAIDashboardFetcher.shouldWaitForUsageBreakdownRecovery(.init(
            now: now,
            errorFirstSeenAt: now.addingTimeInterval(-1.0)))
        #expect(shouldWait == true)
    }

    @Test
    func `usage breakdown recovery stops blocking partial snapshots`() {
        let now = Date()
        let shouldWait = OpenAIDashboardFetcher.shouldWaitForUsageBreakdownRecovery(.init(
            now: now,
            errorFirstSeenAt: now.addingTimeInterval(-5.0)))
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
    func `probe handoff preserves page only after confirmed signed in email`() {
        let result = OpenAIDashboardFetcher.ProbeResult(
            href: "https://chatgpt.com/codex/cloud/settings/analytics#usage",
            loginRequired: false,
            workspacePicker: false,
            cloudflareInterstitial: false,
            signedInEmail: "user@example.com",
            bodyText: "Credits remaining 42")

        #expect(OpenAIDashboardFetcher.shouldPreserveLoadedPageAfterProbe(result))
    }

    @Test
    func `probe handoff does not preserve timed out usage page without email`() {
        let result = OpenAIDashboardFetcher.ProbeResult(
            href: "https://chatgpt.com/codex/cloud/settings/analytics#usage",
            loginRequired: false,
            workspacePicker: false,
            cloudflareInterstitial: false,
            signedInEmail: nil,
            bodyText: "Codex Analytics")

        #expect(!OpenAIDashboardFetcher.shouldPreserveLoadedPageAfterProbe(result))
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
    func `usage route matcher accepts analytics route`() {
        #expect(OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/codex/cloud/settings/analytics"))
    }

    @Test
    func `usage route matcher accepts analytics usage hash route`() {
        #expect(OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/codex/cloud/settings/analytics#usage"))
    }

    @Test
    func `usage route matcher accepts trailing slash variants`() {
        #expect(OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/codex/settings/usage/"))
        #expect(OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/codex/cloud/settings/usage/"))
        #expect(OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/codex/cloud/settings/analytics/"))
    }

    @Test
    func `usage route matcher rejects unrelated routes`() {
        #expect(!OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/"))
        #expect(!OpenAIDashboardFetcher.isUsageRoute("https://chatgpt.com/codex"))
        #expect(!OpenAIDashboardFetcher.isUsageRoute(nil))
    }

    @Test
    func `dashboard requests prefer English localization`() throws {
        let url = try #require(URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage"))
        let request = OpenAIDashboardFetcher.usageURLRequest(url: url)
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
    }

    @Test
    func `usage api request carries cookies and English localization`() {
        let request = OpenAIDashboardFetcher.dashboardUsageAPIRequest(cookieHeader: "a=b")
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "a=b")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
    }

    @Test
    func `identity api request carries cookies and English localization`() throws {
        let url = try #require(URL(string: "https://chatgpt.com/backend-api/me"))
        let request = OpenAIDashboardFetcher.dashboardIdentityAPIRequest(url: url, cookieHeader: "a=b")

        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/me")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "a=b")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
    }

    @Test
    func `usage api data maps language independent rate limits and credits`() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 12,
              "reset_at": 1700003600,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 34,
              "reset_at": 1700604800,
              "limit_window_seconds": 604800
            }
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": 42.5
          }
        }
        """
        let response = try CodexOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
        let data = OpenAIDashboardFetcher.dashboardAPIData(from: response)

        #expect(data.primaryLimit?.usedPercent == 12)
        #expect(data.primaryLimit?.windowMinutes == 300)
        #expect(data.secondaryLimit?.usedPercent == 34)
        #expect(data.secondaryLimit?.windowMinutes == 10080)
        #expect(data.creditsRemaining == 42.5)
        #expect(data.accountPlan == "pro")
        #expect(data.hasUsageData)
    }

    @Test
    func `find first email searches nested api payloads`() {
        let json = """
        {
          "accounts": [
            { "profile": { "name": "Test" } },
            { "profile": { "email": "nested@example.com" } }
          ]
        }
        """

        #expect(OpenAIDashboardFetcher.findFirstEmail(inJSONData: Data(json.utf8)) == "nested@example.com")
    }
}
