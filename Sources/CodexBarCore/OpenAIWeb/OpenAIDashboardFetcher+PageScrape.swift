#if os(macOS)
import Foundation
import WebKit

extension OpenAIDashboardFetcher {
    struct PageScrapeContext {
        let webView: WKWebView
        let apiData: DashboardAPIData?
        let verifiedSignedInEmail: String?
        let subscriptionResult: OpenAISubscriptionFetchResult
        let previousSnapshot: OpenAIDashboardSnapshot?
        let deadline: Date
        let startedAt: Date
        let debugDumpHTML: Bool
        let log: (String) -> Void
    }

    struct ReadinessProbe {
        let loginRequired: Bool
        let workspacePicker: Bool
        let cloudflareInterstitial: Bool
        let href: String?
        let signedInEmail: String?
        let authStatus: String?
        let creditsHeaderPresent: Bool
        let creditsHeaderInViewport: Bool
        let didScrollToCredits: Bool
        let rowCount: Int
        let usageBreakdownReady: Bool
        let hasCodeReviewSignal: Bool
        let hasDashboardSignal: Bool
    }

    func collectPageSnapshot(_ context: PageScrapeContext) async throws -> OpenAIDashboardSnapshot {
        let webView = context.webView
        let apiData = context.apiData
        let verifiedSignedInEmail = context.verifiedSignedInEmail
        let subscriptionResult = context.subscriptionResult
        let previousSnapshot = context.previousSnapshot
        let deadline = context.deadline
        let startedAt = context.startedAt
        let debugDumpHTML = context.debugDumpHTML
        let log = context.log
        var lastBody: String?
        var lastHref: String?
        var lastFlags: (loginRequired: Bool, workspacePicker: Bool, cloudflare: Bool)?
        var codeReviewFirstSeenAt: Date?
        var anyDashboardSignalAt: Date?
        var creditsHeaderVisibleAt: Date?
        var usageBreakdownErrorFirstSeenAt: Date?
        var lastUsageBreakdownError: String?

        while Date() < deadline {
            try Task.checkCancellation()
            let probe = try await self.probeReadiness(webView: webView)

            if probe.href != lastHref
                || lastFlags?.loginRequired != probe.loginRequired
                || lastFlags?.workspacePicker != probe.workspacePicker
                || lastFlags?.cloudflare != probe.cloudflareInterstitial
            {
                lastHref = probe.href
                lastFlags = (probe.loginRequired, probe.workspacePicker, probe.cloudflareInterstitial)
                let href = probe.href ?? "nil"
                log(
                    "href=\(href) login=\(probe.loginRequired) " +
                        "workspace=\(probe.workspacePicker) cloudflare=\(probe.cloudflareInterstitial)")
            }

            if probe.workspacePicker {
                try await Self.sleepForDashboardPoll(.milliseconds(500))
                continue
            }

            try await self.handleBlockingReadinessState(
                probe,
                webView: webView,
                debugDumpHTML: debugDumpHTML,
                logger: log)

            if Self.shouldReloadUsageRoute(
                href: probe.href,
                loginRequired: probe.loginRequired,
                workspacePicker: probe.workspacePicker,
                cloudflareInterstitial: probe.cloudflareInterstitial)
            {
                _ = webView.load(Self.usageURLRequest(url: self.usageURL))
                try await Self.sleepForDashboardPoll(.milliseconds(500))
                continue
            }

            if probe.hasDashboardSignal, anyDashboardSignalAt == nil {
                anyDashboardSignalAt = Date()
            }
            if probe.hasCodeReviewSignal, codeReviewFirstSeenAt == nil {
                codeReviewFirstSeenAt = Date()
            }
            if probe.creditsHeaderPresent, probe.creditsHeaderInViewport, creditsHeaderVisibleAt == nil {
                creditsHeaderVisibleAt = Date()
            }

            let apiHasReturnableData = apiData?.hasUsageData == true
            if probe.rowCount == 0, probe.hasDashboardSignal || apiHasReturnableData {
                log(
                    "credits header present=\(probe.creditsHeaderPresent) " +
                        "inViewport=\(probe.creditsHeaderInViewport) didScroll=\(probe.didScrollToCredits) " +
                        "rows=\(probe.rowCount)")
                if probe.didScrollToCredits {
                    log("scrollIntoView(Credits usage history) requested; waiting…")
                    try await Self.sleepForDashboardPoll(.milliseconds(600))
                    continue
                }
                if Self.shouldWaitForCreditsHistory(
                    probe: probe,
                    anyDashboardSignalAt: anyDashboardSignalAt,
                    creditsHeaderVisibleAt: creditsHeaderVisibleAt)
                {
                    try await Self.sleepForDashboardPoll(.milliseconds(400))
                    continue
                }
            }

            if probe.hasCodeReviewSignal, !probe.usageBreakdownReady {
                let elapsed = Date().timeIntervalSince(codeReviewFirstSeenAt ?? Date())
                if elapsed < 6 {
                    try await Self.sleepForDashboardPoll(.milliseconds(400))
                    continue
                }
            }

            if !probe.hasDashboardSignal, !apiHasReturnableData {
                try await Self.sleepForDashboardPoll(.milliseconds(500))
                continue
            }

            log("dashboard phase=extract elapsed=\(Self.phaseElapsed(since: startedAt))")
            let scrape = try await self.scrape(webView: webView)
            lastBody = scrape.bodyText ?? lastBody
            let dashboardData = Self.parseDashboardScrape(
                scrape,
                apiData: apiData,
                verifiedSignedInEmail: verifiedSignedInEmail)

            if Self.updateAndShouldWaitForUsageBreakdownRecovery(
                usageBreakdown: dashboardData.usageBreakdown,
                error: scrape.usageBreakdownError,
                firstSeenAt: &usageBreakdownErrorFirstSeenAt,
                lastError: &lastUsageBreakdownError,
                logger: log)
            {
                try await Self.sleepForDashboardPoll(.milliseconds(400))
                continue
            }

            // Placeholder rows can make rowCount > 0 before real credit rows hydrate; keep the
            // pre-extract grace keyed on parsed events like the pre-refactor loop did.
            if dashboardData.events.isEmpty,
               Self.shouldWaitForCreditsHistory(
                   probe: probe,
                   anyDashboardSignalAt: anyDashboardSignalAt,
                   creditsHeaderVisibleAt: creditsHeaderVisibleAt)
            {
                try await Self.sleepForDashboardPoll(.milliseconds(400))
                continue
            }

            if dashboardData.hasReturnableData,
               dashboardData.hasDashboardPageSignal || apiHasReturnableData
            {
                if let purchaseURL = scrape.creditsPurchaseURL {
                    log("credits purchase url: \(purchaseURL)")
                }
                return Self.makePageSnapshot(
                    scrape: scrape,
                    dashboardData: dashboardData,
                    subscriptionResult: subscriptionResult,
                    previousSnapshot: previousSnapshot)
            }

            try await Self.sleepForDashboardPoll(.milliseconds(500))
        }

        if let apiData, apiData.hasUsageData, let verifiedSignedInEmail {
            log("usage api snapshot returned after WebView deadline")
            return Self.snapshotByMergingAPI(
                apiData: apiData,
                verifiedEmail: verifiedSignedInEmail,
                subscriptionResult: subscriptionResult,
                previous: previousSnapshot)
        }

        if debugDumpHTML, let html = try? await self.fetchDebugHTML(webView: webView) {
            Self.writeDebugArtifacts(html: html, bodyText: lastBody, logger: log)
        }
        throw FetchError.noDashboardData(body: lastUsageBreakdownError ?? lastBody ?? "")
    }

    nonisolated static func makePageSnapshot(
        scrape: ScrapeResult,
        dashboardData: DashboardScrapeData,
        subscriptionResult: OpenAISubscriptionFetchResult,
        previousSnapshot: OpenAIDashboardSnapshot?) -> OpenAIDashboardSnapshot
    {
        self.fillingMissingPageFields(
            self.makeDashboardSnapshot(.init(
                signedInEmail: dashboardData.signedInEmail,
                scrape: scrape,
                codeReview: dashboardData.codeReview,
                codeReviewLimit: dashboardData.codeReviewLimit,
                events: dashboardData.events,
                breakdown: dashboardData.breakdown,
                usageBreakdown: dashboardData.usageBreakdown,
                rateLimits: dashboardData.rateLimits,
                extraRateWindows: dashboardData.extraRateWindows,
                creditsRemaining: dashboardData.creditsRemaining,
                codexCreditLimit: dashboardData.codexCreditLimit,
                accountPlan: dashboardData.accountPlan,
                subscription: subscriptionResult.metadata)),
            from: previousSnapshot,
            subscriptionResult: subscriptionResult)
    }

    nonisolated static func shouldWaitForCreditsHistory(
        probe: ReadinessProbe,
        anyDashboardSignalAt: Date?,
        creditsHeaderVisibleAt: Date?,
        now: Date = Date()) -> Bool
    {
        self.shouldWaitForCreditsHistory(.init(
            now: now,
            anyDashboardSignalAt: anyDashboardSignalAt,
            creditsHeaderVisibleAt: creditsHeaderVisibleAt,
            creditsHeaderPresent: probe.creditsHeaderPresent,
            creditsHeaderInViewport: probe.creditsHeaderInViewport,
            didScrollToCredits: probe.didScrollToCredits))
    }

    nonisolated static func updateAndShouldWaitForUsageBreakdownRecovery(
        usageBreakdown: [OpenAIDashboardDailyBreakdown],
        error: String?,
        firstSeenAt: inout Date?,
        lastError: inout String?,
        logger: (String) -> Void) -> Bool
    {
        updateUsageBreakdownErrorState(
            usageBreakdown: usageBreakdown,
            error: error,
            firstSeenAt: &firstSeenAt,
            lastError: &lastError,
            logger: logger)

        guard usageBreakdown.isEmpty, let error, !error.isEmpty else { return false }
        return Self.shouldWaitForUsageBreakdownRecovery(.init(
            now: Date(),
            errorFirstSeenAt: firstSeenAt))
    }
}
#endif
