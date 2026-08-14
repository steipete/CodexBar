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

    @Test(arguments: [
        ("https://chatgpt.com/#usage", true, false, false, false),
        ("https://chatgpt.com/", false, false, true, false),
        ("https://chatgpt.com/", false, false, false, true)
    ])
    func `usage route reload skips blocking states`(
        href: String,
        loginRequired: Bool,
        workspacePicker: Bool,
        cloudflareInterstitial: Bool,
        expected: Bool)
    {
        #expect(OpenAIDashboardFetcher.shouldReloadUsageRoute(
            href: href,
            loginRequired: loginRequired,
            workspacePicker: workspacePicker,
            cloudflareInterstitial: cloudflareInterstitial) == expected)
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
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test
    func `identity api request carries cookies and English localization`() throws {
        let url = try #require(URL(string: "https://chatgpt.com/backend-api/me"))
        let request = OpenAIDashboardFetcher.dashboardIdentityAPIRequest(url: url, cookieHeader: "a=b")

        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/me")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "a=b")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test
    func `dashboard api requests accept shared deadline timeout clamps`() throws {
        let url = try #require(URL(string: "https://chatgpt.com/backend-api/me"))
        let usageRequest = OpenAIDashboardFetcher.dashboardUsageAPIRequest(
            cookieHeader: "a=b",
            timeout: 1.25)
        let identityRequest = OpenAIDashboardFetcher.dashboardIdentityAPIRequest(
            url: url,
            cookieHeader: "a=b",
            timeout: 0.75)

        #expect(usageRequest.timeoutInterval == 1.25)
        #expect(identityRequest.timeoutInterval == 0.75)
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

    @Test
    func `api merge prefers the page derived plan over the generic api plan`() {
        let previous = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            accountPlan: "Pro 5x",
            updatedAt: Date(timeIntervalSince1970: 1))
        let apiData = OpenAIDashboardFetcher.DashboardAPIData(
            primaryLimit: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondaryLimit: nil,
            extraRateWindows: [],
            creditsRemaining: nil,
            codexCreditLimit: nil,
            accountPlan: "pro")

        let snapshot = OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: apiData,
            verifiedEmail: "user@example.com",
            subscription: nil,
            previous: previous,
            updatedAt: Date(timeIntervalSince1970: 2))

        #expect(snapshot.accountPlan == "Pro 5x")
    }

    @Test
    func `placeholder rows still wait for parsed credit events before extract accepts`() {
        let now = Date()
        // rowCount > 0 in the readiness probe skipped the pre-extract wait; the post-extract
        // guard must still hold while parsed events are empty and the grace window is open.
        let probe = OpenAIDashboardFetcher.ReadinessProbe(
            loginRequired: false,
            workspacePicker: false,
            cloudflareInterstitial: false,
            href: "https://chatgpt.com/codex/cloud/settings/analytics#usage",
            signedInEmail: "user@example.com",
            authStatus: "logged_in",
            creditsHeaderPresent: true,
            creditsHeaderInViewport: true,
            didScrollToCredits: false,
            rowCount: 3,
            usageBreakdownReady: true,
            hasCodeReviewSignal: false,
            hasDashboardSignal: true)

        #expect(OpenAIDashboardFetcher.shouldWaitForCreditsHistory(
            probe: probe,
            anyDashboardSignalAt: now.addingTimeInterval(-1),
            creditsHeaderVisibleAt: now.addingTimeInterval(-1),
            now: now))
        #expect(!OpenAIDashboardFetcher.shouldWaitForCreditsHistory(
            probe: probe,
            anyDashboardSignalAt: now.addingTimeInterval(-10),
            creditsHeaderVisibleAt: now.addingTimeInterval(-3),
            now: now))
    }

    @Test
    func `page scrape is skipped whenever the caller disables it`() {
        #expect(OpenAIDashboardFetcher.shouldSkipPageScrape(allowPageScrape: false))
        #expect(!OpenAIDashboardFetcher.shouldSkipPageScrape(allowPageScrape: true))
    }

    @Test
    func `api snapshot keeps previous credits history and overwrites live usage`() {
        let previous = OpenAIDashboardSnapshot(
            signedInEmail: "old@example.com",
            codeReviewRemainingPercent: 81,
            creditEvents: [
                CreditEvent(date: Date(timeIntervalSince1970: 1_700_000_000), service: "Codex", creditsUsed: 2),
            ],
            dailyBreakdown: [
                OpenAIDashboardDailyBreakdown(
                    day: "2026-04-19",
                    services: [OpenAIDashboardServiceUsage(service: "Codex", creditsUsed: 2)],
                    totalCreditsUsed: 2),
            ],
            usageBreakdown: [
                OpenAIDashboardDailyBreakdown(
                    day: "2026-04-19",
                    services: [OpenAIDashboardServiceUsage(service: "Codex", creditsUsed: 2)],
                    totalCreditsUsed: 2),
            ],
            creditsPurchaseURL: "https://chatgpt.com/checkout",
            primaryLimit: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            creditsRemaining: 10,
            updatedAt: Date(timeIntervalSince1970: 1))
        let apiData = OpenAIDashboardFetcher.DashboardAPIData(
            primaryLimit: RateWindow(usedPercent: 44, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondaryLimit: nil,
            extraRateWindows: [],
            creditsRemaining: 7.5,
            codexCreditLimit: nil,
            accountPlan: "pro")
        let subscription = OpenAISubscriptionMetadata.parse(
            activeUntil: "2026-08-20T14:30:07Z",
            willRenew: true)

        let snapshot = OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: apiData,
            verifiedEmail: "new@example.com",
            subscription: subscription,
            previous: previous,
            updatedAt: Date(timeIntervalSince1970: 2))

        #expect(snapshot.signedInEmail == "new@example.com")
        #expect(snapshot.primaryLimit?.usedPercent == 44)
        #expect(snapshot.creditsRemaining == 7.5)
        #expect(snapshot.accountPlan == "pro")
        #expect(snapshot.creditEvents.count == 1)
        #expect(snapshot.dailyBreakdown.count == 1)
        #expect(snapshot.usageBreakdown.count == 1)
        #expect(snapshot.codeReviewRemainingPercent == 81)
        #expect(snapshot.creditsPurchaseURL == "https://chatgpt.com/checkout")
        #expect(snapshot.subscriptionRenewsAt != nil)
    }

    @Test
    func `subscription replacement clears the mutually exclusive previous date`() {
        let previous = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            subscriptionRenewsAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1))
        let apiData = OpenAIDashboardFetcher.DashboardAPIData(
            primaryLimit: nil,
            secondaryLimit: nil,
            extraRateWindows: [],
            creditsRemaining: nil,
            codexCreditLimit: nil,
            accountPlan: nil)
        let subscription = OpenAISubscriptionMetadata.parse(
            activeUntil: "2026-08-20T14:30:07Z",
            willRenew: false)

        let snapshot = OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: apiData,
            verifiedEmail: "user@example.com",
            subscription: subscription,
            previous: previous,
            updatedAt: Date(timeIntervalSince1970: 2))

        #expect(snapshot.subscriptionExpiresAt != nil)
        #expect(snapshot.subscriptionRenewsAt == nil)
    }

    @Test
    func `page field subscription replacement clears the mutually exclusive previous date`() {
        let previous = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            subscriptionRenewsAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1))
        let incoming = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            subscriptionExpiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            updatedAt: Date(timeIntervalSince1970: 2))
        let subscription = OpenAISubscriptionMetadata.parse(
            activeUntil: "2026-08-20T14:30:07Z",
            willRenew: false)

        let snapshot = OpenAIDashboardFetcher.fillingMissingPageFields(
            incoming,
            from: previous,
            subscription: subscription)

        #expect(snapshot.subscriptionExpiresAt != nil)
        #expect(snapshot.subscriptionRenewsAt == nil)
    }

    @Test
    func `empty scrape keeps previous page history`() {
        let previous = OpenAIDashboardSnapshot(
            signedInEmail: "keep@example.com",
            codeReviewRemainingPercent: 70,
            creditEvents: [
                CreditEvent(date: Date(timeIntervalSince1970: 1_700_000_000), service: "Codex", creditsUsed: 3),
            ],
            dailyBreakdown: [
                OpenAIDashboardDailyBreakdown(
                    day: "2026-04-19",
                    services: [OpenAIDashboardServiceUsage(service: "Codex", creditsUsed: 3)],
                    totalCreditsUsed: 3),
            ],
            usageBreakdown: [
                OpenAIDashboardDailyBreakdown(
                    day: "2026-04-19",
                    services: [OpenAIDashboardServiceUsage(service: "Codex", creditsUsed: 3)],
                    totalCreditsUsed: 3),
            ],
            creditsPurchaseURL: "https://chatgpt.com/checkout",
            creditsRemaining: 8,
            subscriptionRenewsAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1))
        let incoming = OpenAIDashboardSnapshot(
            signedInEmail: nil,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            primaryLimit: RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            creditsRemaining: 6,
            updatedAt: Date(timeIntervalSince1970: 2))

        let snapshot = OpenAIDashboardFetcher.fillingMissingPageFields(incoming, from: previous)
        #expect(snapshot.signedInEmail == "keep@example.com")
        #expect(snapshot.codeReviewRemainingPercent == 70)
        #expect(snapshot.creditEvents.count == 1)
        #expect(snapshot.dailyBreakdown.count == 1)
        #expect(snapshot.usageBreakdown.count == 1)
        #expect(snapshot.creditsPurchaseURL == "https://chatgpt.com/checkout")
        #expect(snapshot.primaryLimit?.usedPercent == 50)
        #expect(snapshot.creditsRemaining == 6)
        #expect(snapshot.subscriptionRenewsAt != nil)
    }

    @Test
    func `subscription api request carries cookies and English localization`() {
        let request = OpenAIDashboardFetcher.dashboardSubscriptionAPIRequest(cookieHeader: "a=b")
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/subscriptions")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "a=b")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test
    func `subscription api payload maps renewal date`() {
        let json = #"{"active_until":"2026-08-20T14:30:07Z","will_renew":true}"#
        let metadata = OpenAIDashboardFetcher.subscriptionMetadata(from: Data(json.utf8))
        #expect(metadata?.renewsAt != nil)
        #expect(metadata?.expiresAt == nil)
    }
}
