#if os(macOS)
import CoreGraphics
import Foundation
import WebKit

@MainActor
public struct OpenAIDashboardFetcher {
    public enum FetchError: LocalizedError {
        case loginRequired
        case noDashboardData(body: String)

        public var errorDescription: String? {
            switch self {
            case .loginRequired:
                "OpenAI web access requires login."
            case let .noDashboardData(body):
                "OpenAI dashboard data not found. Body sample: \(body.prefix(200))"
            }
        }
    }

    private let usageURL = URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage")!
    private nonisolated static let dashboardAcceptLanguage = "en-US,en;q=0.9"
    private nonisolated static let dashboardUsageAPIURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init() {}

    public nonisolated static func offscreenHostWindowFrame(for visibleFrame: CGRect) -> CGRect {
        let width: CGFloat = min(1200, visibleFrame.width)
        let height: CGFloat = min(1600, visibleFrame.height)

        // Keep the WebView "visible" for WebKit hydration, but never show it to the user.
        // Place the window almost entirely off-screen; leave only a 1×1 px intersection.
        let sliver: CGFloat = 1
        return CGRect(
            x: visibleFrame.maxX - sliver,
            y: visibleFrame.maxY - sliver,
            width: width,
            height: height)
    }

    public nonisolated static func offscreenHostAlphaValue() -> CGFloat {
        // Must be > 0 or WebKit can throttle hydration/timers on the Codex usage SPA.
        0.001
    }

    private struct DashboardSnapshotComponents {
        let signedInEmail: String?
        let scrape: ScrapeResult
        let codeReview: Double?
        let codeReviewLimit: RateWindow?
        let events: [CreditEvent]
        let breakdown: [OpenAIDashboardDailyBreakdown]
        let usageBreakdown: [OpenAIDashboardDailyBreakdown]
        let rateLimits: (primary: RateWindow?, secondary: RateWindow?)
        let creditsRemaining: Double?
        let accountPlan: String?
    }

    private struct DashboardScrapeData {
        let signedInEmail: String?
        let codeReview: Double?
        let codeReviewLimit: RateWindow?
        let events: [CreditEvent]
        let breakdown: [OpenAIDashboardDailyBreakdown]
        let usageBreakdown: [OpenAIDashboardDailyBreakdown]
        let rateLimits: (primary: RateWindow?, secondary: RateWindow?)
        let creditsRemaining: Double?
        let accountPlan: String?
        let hasDashboardPageSignal: Bool
        let hasReturnableData: Bool
    }

    private nonisolated static func makeDashboardSnapshot(_ components: DashboardSnapshotComponents)
        -> OpenAIDashboardSnapshot
    {
        OpenAIDashboardSnapshot(
            signedInEmail: components.signedInEmail,
            codeReviewRemainingPercent: components.codeReview,
            codeReviewLimit: components.codeReviewLimit,
            creditEvents: components.events,
            dailyBreakdown: components.breakdown,
            usageBreakdown: components.usageBreakdown,
            creditsPurchaseURL: components.scrape.creditsPurchaseURL,
            primaryLimit: components.rateLimits.primary,
            secondaryLimit: components.rateLimits.secondary,
            creditsRemaining: components.creditsRemaining,
            accountPlan: components.accountPlan,
            updatedAt: Date())
    }

    private static func parseDashboardScrape(
        _ scrape: ScrapeResult,
        apiData: DashboardAPIData?,
        verifiedSignedInEmail: String?) -> DashboardScrapeData
    {
        let bodyText = scrape.bodyText ?? ""
        let codeReview = OpenAIDashboardParser.parseCodeReviewRemainingPercent(bodyText: bodyText)
        let events = OpenAIDashboardParser.parseCreditEvents(rows: scrape.rows)
        let breakdown = OpenAIDashboardSnapshot.makeDailyBreakdown(from: events, maxDays: 30)
        let usageBreakdown = scrape.usageBreakdown
        let parsedRateLimits = OpenAIDashboardParser.parseRateLimits(bodyText: bodyText)
        let rateLimits = (
            primary: apiData?.primaryLimit ?? parsedRateLimits.primary,
            secondary: apiData?.secondaryLimit ?? parsedRateLimits.secondary)
        let codeReviewLimit = OpenAIDashboardParser.parseCodeReviewLimit(bodyText: bodyText)
        let parsedCreditsRemaining = OpenAIDashboardParser.parseCreditsRemaining(bodyText: bodyText)
        let creditsRemaining = apiData?.creditsRemaining ?? parsedCreditsRemaining
        let parsedAccountPlan = scrape.bodyHTML.flatMap(OpenAIDashboardParser.parsePlanFromHTML)
        let accountPlan = parsedAccountPlan ?? apiData?.accountPlan
        let hasParsedUsageLimits = parsedRateLimits.primary != nil || parsedRateLimits.secondary != nil
        let hasUsageLimits = rateLimits.primary != nil || rateLimits.secondary != nil
        let hasDashboardPageData = self.hasReturnableDashboardData(
            codeReview: codeReview,
            events: events,
            usageBreakdown: usageBreakdown,
            hasUsageLimits: hasParsedUsageLimits,
            creditsRemaining: parsedCreditsRemaining)
        let hasReturnableData = self.hasReturnableDashboardData(
            codeReview: codeReview,
            events: events,
            usageBreakdown: usageBreakdown,
            hasUsageLimits: hasUsageLimits,
            creditsRemaining: creditsRemaining)

        return DashboardScrapeData(
            signedInEmail: self.firstNonEmpty(scrape.signedInEmail, verifiedSignedInEmail),
            codeReview: codeReview,
            codeReviewLimit: codeReviewLimit,
            events: events,
            breakdown: breakdown,
            usageBreakdown: usageBreakdown,
            rateLimits: rateLimits,
            creditsRemaining: creditsRemaining,
            accountPlan: accountPlan,
            hasDashboardPageSignal: self.hasAnyDashboardSignal(
                hasReturnableData: hasDashboardPageData,
                creditsHeaderPresent: scrape.creditsHeaderPresent),
            hasReturnableData: hasReturnableData)
    }

    struct DashboardAPIData {
        let primaryLimit: RateWindow?
        let secondaryLimit: RateWindow?
        let creditsRemaining: Double?
        let accountPlan: String?

        var hasUsageData: Bool {
            self.primaryLimit != nil || self.secondaryLimit != nil || self.creditsRemaining != nil
        }
    }

    public struct ProbeResult: Sendable {
        public let href: String?
        public let loginRequired: Bool
        public let workspacePicker: Bool
        public let cloudflareInterstitial: Bool
        public let signedInEmail: String?
        public let bodyText: String?

        public init(
            href: String?,
            loginRequired: Bool,
            workspacePicker: Bool,
            cloudflareInterstitial: Bool,
            signedInEmail: String?,
            bodyText: String?)
        {
            self.href = href
            self.loginRequired = loginRequired
            self.workspacePicker = workspacePicker
            self.cloudflareInterstitial = cloudflareInterstitial
            self.signedInEmail = signedInEmail
            self.bodyText = bodyText
        }
    }

    nonisolated static func shouldPreserveLoadedPageAfterProbe(_ result: ProbeResult) -> Bool {
        guard !result.loginRequired, !result.workspacePicker, !result.cloudflareInterstitial else {
            return false
        }

        guard self.isUsageRoute(result.href) else { return false }

        guard let signedInEmail = result.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !signedInEmail.isEmpty
        else {
            return false
        }

        return true
    }

    public func loadLatestDashboard(
        accountEmail: String?,
        logger: ((String) -> Void)? = nil,
        debugDumpHTML: Bool = false,
        timeout: TimeInterval = 60) async throws -> OpenAIDashboardSnapshot
    {
        let store = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: accountEmail)
        return try await self.loadLatestDashboard(
            websiteDataStore: store,
            logger: logger,
            debugDumpHTML: debugDumpHTML,
            timeout: timeout)
    }

    public func loadLatestDashboard(
        websiteDataStore: WKWebsiteDataStore,
        logger: ((String) -> Void)? = nil,
        debugDumpHTML: Bool = false,
        timeout: TimeInterval = 60) async throws -> OpenAIDashboardSnapshot
    {
        let deadline = Self.deadline(startingAt: Date(), timeout: timeout)
        let preflight = await Self.fetchDashboardAPIPreflight(
            websiteDataStore: websiteDataStore,
            logger: { logger?($0) })
        let apiData = preflight.apiData
        let verifiedSignedInEmail = preflight.verifiedSignedInEmail

        let lease = try await self.makeWebView(
            websiteDataStore: websiteDataStore,
            logger: logger,
            timeout: Self.remainingTimeout(until: deadline))
        defer { lease.release() }
        let webView = lease.webView
        let log = lease.log

        var lastBody: String?
        var lastHTML: String?
        var lastHref: String?
        var lastFlags: (loginRequired: Bool, workspacePicker: Bool, cloudflare: Bool)?
        var codeReviewFirstSeenAt: Date?
        var anyDashboardSignalAt: Date?
        var creditsHeaderVisibleAt: Date?
        var usageBreakdownErrorFirstSeenAt: Date?
        var lastUsageBreakdownDebug: String?
        var lastUsageBreakdownError: String?
        var lastCreditsPurchaseURL: String?
        while Date() < deadline {
            let scrape = try await self.scrape(webView: webView)
            lastBody = scrape.bodyText ?? lastBody
            lastHTML = scrape.bodyHTML ?? lastHTML

            if scrape.href != lastHref
                || lastFlags?.loginRequired != scrape.loginRequired
                || lastFlags?.workspacePicker != scrape.workspacePicker
                || lastFlags?.cloudflare != scrape.cloudflareInterstitial
            {
                lastHref = scrape.href
                lastFlags = (scrape.loginRequired, scrape.workspacePicker, scrape.cloudflareInterstitial)
                let href = scrape.href ?? "nil"
                log(
                    "href=\(href) login=\(scrape.loginRequired) " +
                        "workspace=\(scrape.workspacePicker) cloudflare=\(scrape.cloudflareInterstitial)")
            }

            if scrape.workspacePicker {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            // The page is a SPA and can land on ChatGPT UI or other routes; keep forcing the usage URL.
            if let href = scrape.href, !Self.isUsageRoute(href) {
                _ = webView.load(Self.usageURLRequest(url: self.usageURL))
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            try Self.throwIfBlockingScrapeState(scrape, debugDumpHTML: debugDumpHTML, logger: log)

            let dashboardData = Self.parseDashboardScrape(
                scrape,
                apiData: apiData,
                verifiedSignedInEmail: verifiedSignedInEmail)
            let codeReview = dashboardData.codeReview
            let events = dashboardData.events
            let usageBreakdown = dashboardData.usageBreakdown
            let hasDashboardPageSignal = dashboardData.hasDashboardPageSignal
            let hasReturnableData = dashboardData.hasReturnableData

            if codeReview != nil, codeReviewFirstSeenAt == nil { codeReviewFirstSeenAt = Date() }
            if anyDashboardSignalAt == nil, hasDashboardPageSignal {
                anyDashboardSignalAt = Date()
            }
            if codeReview != nil, usageBreakdown.isEmpty,
               let debug = scrape.usageBreakdownDebug, !debug.isEmpty,
               debug != lastUsageBreakdownDebug
            {
                lastUsageBreakdownDebug = debug
                log("usage breakdown debug: \(debug)")
            }
            Self.updateUsageBreakdownErrorState(
                usageBreakdown: usageBreakdown,
                error: scrape.usageBreakdownError,
                firstSeenAt: &usageBreakdownErrorFirstSeenAt,
                lastError: &lastUsageBreakdownError,
                logger: log)
            if let purchaseURL = scrape.creditsPurchaseURL, purchaseURL != lastCreditsPurchaseURL {
                lastCreditsPurchaseURL = purchaseURL
                log("credits purchase url: \(purchaseURL)")
            }
            if events.isEmpty,
               hasReturnableData,
               hasDashboardPageSignal
            {
                log(
                    "credits header present=\(scrape.creditsHeaderPresent) " +
                        "inViewport=\(scrape.creditsHeaderInViewport) didScroll=\(scrape.didScrollToCredits) " +
                        "rows=\(scrape.rows.count)")
                if scrape.didScrollToCredits {
                    log("scrollIntoView(Credits usage history) requested; waiting…")
                    try? await Task.sleep(for: .milliseconds(600))
                    continue
                }

                // Avoid returning early when the usage breakdown chart hydrates before the (often virtualized)
                // credits table. When we detect a dashboard signal, give credits history a moment to appear.
                if scrape.creditsHeaderPresent, scrape.creditsHeaderInViewport, creditsHeaderVisibleAt == nil {
                    creditsHeaderVisibleAt = Date()
                }
                if Self.shouldWaitForCreditsHistory(.init(
                    now: Date(),
                    anyDashboardSignalAt: anyDashboardSignalAt,
                    creditsHeaderVisibleAt: creditsHeaderVisibleAt,
                    creditsHeaderPresent: scrape.creditsHeaderPresent,
                    creditsHeaderInViewport: scrape.creditsHeaderInViewport,
                    didScrollToCredits: scrape.didScrollToCredits))
                {
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }
            }

            if hasReturnableData, hasDashboardPageSignal {
                if usageBreakdown.isEmpty,
                   let error = scrape.usageBreakdownError, !error.isEmpty,
                   Self.shouldWaitForUsageBreakdownRecovery(.init(
                       now: Date(),
                       errorFirstSeenAt: usageBreakdownErrorFirstSeenAt))
                {
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }

                // The usage breakdown chart is hydrated asynchronously. When code review is already present,
                // give it a moment to populate so the menu can show it.
                if codeReview != nil, usageBreakdown.isEmpty {
                    let elapsed = Date().timeIntervalSince(codeReviewFirstSeenAt ?? Date())
                    if elapsed < 6 {
                        try? await Task.sleep(for: .milliseconds(400))
                        continue
                    }
                }
                return Self.makeDashboardSnapshot(.init(
                    signedInEmail: dashboardData.signedInEmail,
                    scrape: scrape,
                    codeReview: codeReview,
                    codeReviewLimit: dashboardData.codeReviewLimit,
                    events: events,
                    breakdown: dashboardData.breakdown,
                    usageBreakdown: usageBreakdown,
                    rateLimits: dashboardData.rateLimits,
                    creditsRemaining: dashboardData.creditsRemaining,
                    accountPlan: dashboardData.accountPlan))
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        if debugDumpHTML, let html = lastHTML {
            Self.writeDebugArtifacts(html: html, bodyText: lastBody, logger: log)
        }
        throw FetchError.noDashboardData(body: lastUsageBreakdownError ?? lastBody ?? "")
    }

    nonisolated static func hasReturnableDashboardData(
        codeReview: Double?,
        events: [CreditEvent],
        usageBreakdown: [OpenAIDashboardDailyBreakdown],
        hasUsageLimits: Bool,
        creditsRemaining: Double?) -> Bool
    {
        codeReview != nil || !events.isEmpty || !usageBreakdown.isEmpty || hasUsageLimits || creditsRemaining != nil
    }

    nonisolated static func hasAnyDashboardSignal(
        hasReturnableData: Bool,
        creditsHeaderPresent: Bool) -> Bool
    {
        hasReturnableData || creditsHeaderPresent
    }

    public func clearSessionData(accountEmail: String?) async {
        let store = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: accountEmail)
        OpenAIDashboardWebViewCache.shared.evict(websiteDataStore: store)
        await OpenAIDashboardWebsiteDataStore.clearStore(forAccountEmail: accountEmail)
    }

    public static func evictAllCachedWebViews() {
        OpenAIDashboardWebViewCache.shared.evictAll()
    }

    public func probeUsagePage(
        websiteDataStore: WKWebsiteDataStore,
        logger: ((String) -> Void)? = nil,
        timeout: TimeInterval = 30,
        preserveLoadedPageForReuse: Bool = false) async throws -> ProbeResult
    {
        let deadline = Self.deadline(startingAt: Date(), timeout: timeout)
        let lease = try await self.makeWebView(
            websiteDataStore: websiteDataStore,
            logger: logger,
            timeout: Self.remainingTimeout(until: deadline),
            preserveLoadedPageOnRelease: preserveLoadedPageForReuse)
        defer { lease.release() }
        let webView = lease.webView
        let log = lease.log

        var lastBody: String?
        var lastHref: String?
        var usageRouteSeenAt: Date?
        var dashboardSignalSeenAt: Date?

        while Date() < deadline {
            let scrape = try await self.scrape(webView: webView)
            lastBody = scrape.bodyText ?? lastBody
            lastHref = scrape.href ?? lastHref

            if scrape.workspacePicker {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            if let href = scrape.href, !Self.isUsageRoute(href) {
                usageRouteSeenAt = nil
                dashboardSignalSeenAt = nil
                _ = webView.load(Self.usageURLRequest(url: self.usageURL))
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            if scrape.loginRequired { throw FetchError.loginRequired }
            if scrape.cloudflareInterstitial {
                throw FetchError.noDashboardData(body: "Cloudflare challenge detected in WebView.")
            }

            let normalizedEmail = scrape.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyText = scrape.bodyText ?? ""
            let rateLimits = OpenAIDashboardParser.parseRateLimits(bodyText: bodyText)
            let hasDashboardSignal = normalizedEmail?.isEmpty == false ||
                !scrape.rows.isEmpty ||
                !scrape.usageBreakdown.isEmpty ||
                scrape.creditsHeaderPresent ||
                OpenAIDashboardParser.parseCodeReviewRemainingPercent(bodyText: bodyText) != nil ||
                OpenAIDashboardParser.parseCreditsRemaining(bodyText: bodyText) != nil ||
                rateLimits.primary != nil ||
                rateLimits.secondary != nil

            if usageRouteSeenAt == nil {
                usageRouteSeenAt = Date()
            }
            if hasDashboardSignal, dashboardSignalSeenAt == nil {
                dashboardSignalSeenAt = Date()
            }
            if Self.shouldWaitForProbeReadiness(.init(
                now: Date(),
                usageRouteSeenAt: usageRouteSeenAt,
                dashboardSignalSeenAt: dashboardSignalSeenAt,
                signedInEmail: normalizedEmail,
                hasDashboardSignal: hasDashboardSignal))
            {
                try? await Task.sleep(for: .milliseconds(400))
                continue
            }

            let result = ProbeResult(
                href: scrape.href,
                loginRequired: scrape.loginRequired,
                workspacePicker: scrape.workspacePicker,
                cloudflareInterstitial: scrape.cloudflareInterstitial,
                signedInEmail: normalizedEmail,
                bodyText: scrape.bodyText)
            lease.setPreserveLoadedPageOnRelease(
                preserveLoadedPageForReuse && Self.shouldPreserveLoadedPageAfterProbe(result))
            return result
        }

        log("Probe timed out (href=\(lastHref ?? "nil"))")
        let result = ProbeResult(
            href: lastHref,
            loginRequired: false,
            workspacePicker: false,
            cloudflareInterstitial: false,
            signedInEmail: nil,
            bodyText: lastBody)
        lease.setPreserveLoadedPageOnRelease(false)
        return result
    }

    // MARK: - JS scrape

    private struct ScrapeResult {
        let loginRequired: Bool
        let workspacePicker: Bool
        let cloudflareInterstitial: Bool
        let href: String?
        let bodyText: String?
        let bodyHTML: String?
        let signedInEmail: String?
        let creditsPurchaseURL: String?
        let rows: [[String]]
        let usageBreakdown: [OpenAIDashboardDailyBreakdown]
        let usageBreakdownDebug: String?
        let usageBreakdownError: String?
        let scrollY: Double
        let scrollHeight: Double
        let viewportHeight: Double
        let creditsHeaderPresent: Bool
        let creditsHeaderInViewport: Bool
        let didScrollToCredits: Bool
    }

    private func scrape(webView: WKWebView) async throws -> ScrapeResult {
        let any = try await webView.evaluateJavaScript(openAIDashboardScrapeScript)
        guard let dict = any as? [String: Any] else {
            return ScrapeResult(
                loginRequired: true,
                workspacePicker: false,
                cloudflareInterstitial: false,
                href: nil,
                bodyText: nil,
                bodyHTML: nil,
                signedInEmail: nil,
                creditsPurchaseURL: nil,
                rows: [],
                usageBreakdown: [],
                usageBreakdownDebug: nil,
                usageBreakdownError: nil,
                scrollY: 0,
                scrollHeight: 0,
                viewportHeight: 0,
                creditsHeaderPresent: false,
                creditsHeaderInViewport: false,
                didScrollToCredits: false)
        }

        var loginRequired = (dict["loginRequired"] as? Bool) ?? false
        let workspacePicker = (dict["workspacePicker"] as? Bool) ?? false
        let cloudflareInterstitial = (dict["cloudflareInterstitial"] as? Bool) ?? false
        let rows = (dict["rows"] as? [[String]]) ?? []
        let bodyHTML = dict["bodyHTML"] as? String

        var usageBreakdown: [OpenAIDashboardDailyBreakdown] = []
        let usageBreakdownDebug = dict["usageBreakdownDebug"] as? String
        let usageBreakdownError = dict["usageBreakdownError"] as? String
        if let raw = dict["usageBreakdownJSON"] as? String, !raw.isEmpty {
            do {
                let decoder = JSONDecoder()
                let decoded = try decoder.decode([OpenAIDashboardDailyBreakdown].self, from: Data(raw.utf8))
                usageBreakdown = OpenAIDashboardDailyBreakdown.removingSkillUsageServices(from: decoded)
            } catch {
                // Best-effort parse; ignore errors to avoid blocking other dashboard data.
                usageBreakdown = []
            }
        }

        var signedInEmail = dict["signedInEmail"] as? String
        if let bodyHTML,
           signedInEmail == nil || signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
        {
            signedInEmail = OpenAIDashboardParser.parseSignedInEmailFromClientBootstrap(html: bodyHTML)
        }

        if let bodyHTML, let authStatus = OpenAIDashboardParser.parseAuthStatusFromClientBootstrap(html: bodyHTML) {
            if authStatus.lowercased() != "logged_in" {
                // When logged out, the SPA can render a generic landing shell without obvious auth inputs,
                // so treat it as login-required and let the caller retry cookie import.
                loginRequired = true
            }
        }

        return ScrapeResult(
            loginRequired: loginRequired,
            workspacePicker: workspacePicker,
            cloudflareInterstitial: cloudflareInterstitial,
            href: dict["href"] as? String,
            bodyText: dict["bodyText"] as? String,
            bodyHTML: bodyHTML,
            signedInEmail: signedInEmail,
            creditsPurchaseURL: dict["creditsPurchaseURL"] as? String,
            rows: rows,
            usageBreakdown: usageBreakdown,
            usageBreakdownDebug: usageBreakdownDebug,
            usageBreakdownError: usageBreakdownError,
            scrollY: (dict["scrollY"] as? NSNumber)?.doubleValue ?? 0,
            scrollHeight: (dict["scrollHeight"] as? NSNumber)?.doubleValue ?? 0,
            viewportHeight: (dict["viewportHeight"] as? NSNumber)?.doubleValue ?? 0,
            creditsHeaderPresent: (dict["creditsHeaderPresent"] as? Bool) ?? false,
            creditsHeaderInViewport: (dict["creditsHeaderInViewport"] as? Bool) ?? false,
            didScrollToCredits: (dict["didScrollToCredits"] as? Bool) ?? false)
    }

    private static func throwIfBlockingScrapeState(
        _ scrape: ScrapeResult,
        debugDumpHTML: Bool,
        logger: (String) -> Void) throws
    {
        if scrape.loginRequired {
            if debugDumpHTML, let html = scrape.bodyHTML {
                self.writeDebugArtifacts(html: html, bodyText: scrape.bodyText, logger: logger)
            }
            throw FetchError.loginRequired
        }

        if scrape.cloudflareInterstitial {
            if debugDumpHTML, let html = scrape.bodyHTML {
                self.writeDebugArtifacts(html: html, bodyText: scrape.bodyText, logger: logger)
            }
            throw FetchError.noDashboardData(body: "Cloudflare challenge detected in WebView.")
        }
    }

    private func makeWebView(
        websiteDataStore: WKWebsiteDataStore,
        logger: ((String) -> Void)?,
        timeout: TimeInterval,
        preserveLoadedPageOnRelease: Bool = false) async throws -> OpenAIDashboardWebViewLease
    {
        try await OpenAIDashboardWebViewCache.shared.acquire(
            websiteDataStore: websiteDataStore,
            usageURL: self.usageURL,
            logger: logger,
            navigationTimeout: timeout,
            preserveLoadedPageOnRelease: preserveLoadedPageOnRelease)
    }

    nonisolated static func sanitizedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite, timeout > 0 else { return 1 }
        return timeout
    }

    nonisolated static func deadline(startingAt start: Date, timeout: TimeInterval) -> Date {
        start.addingTimeInterval(self.sanitizedTimeout(timeout))
    }

    nonisolated static func remainingTimeout(until deadline: Date, now: Date = Date()) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }

    nonisolated static func isUsageRoute(_ href: String?) -> Bool {
        guard let href, !href.isEmpty else { return false }
        let path = (URL(string: href)?.path ?? href)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.hasSuffix("codex/settings/usage")
            || path.hasSuffix("codex/cloud/settings/usage")
            || path.hasSuffix("codex/settings/analytics")
            || path.hasSuffix("codex/cloud/settings/analytics")
    }

    nonisolated static func usageURLRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.dashboardAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        return request
    }

    nonisolated static func dashboardUsageAPIRequest(cookieHeader: String) -> URLRequest {
        var request = URLRequest(url: Self.dashboardUsageAPIURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.dashboardAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated static func dashboardIdentityAPIRequest(url: URL, cookieHeader: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.dashboardAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated static func dashboardAPIData(from response: CodexUsageResponse) -> DashboardAPIData {
        DashboardAPIData(
            primaryLimit: self.rateWindow(from: response.rateLimit?.primaryWindow),
            secondaryLimit: self.rateWindow(from: response.rateLimit?.secondaryWindow),
            creditsRemaining: response.credits?.balance,
            accountPlan: response.planType?.rawValue)
    }

    private static func fetchDashboardAPIPreflight(
        websiteDataStore: WKWebsiteDataStore,
        logger: @escaping (String) -> Void)
        async -> (apiData: DashboardAPIData?, verifiedSignedInEmail: String?)
    {
        let cookieHeader = await self.chatGPTCookieHeader(in: websiteDataStore)
        let apiData = await self.fetchDashboardUsageAPI(cookieHeader: cookieHeader, logger: logger)
        let verifiedEmail: String? = if apiData?.hasUsageData == true {
            await self.fetchSignedInEmailFromAPI(cookieHeader: cookieHeader, logger: logger)
        } else {
            nil
        }

        if apiData?.hasUsageData == true, verifiedEmail != nil {
            logger("usage api supplied verified dashboard data; continuing WebView scrape")
        }
        return (apiData, verifiedEmail)
    }

    private static func fetchDashboardUsageAPI(
        websiteDataStore: WKWebsiteDataStore,
        logger: @escaping (String) -> Void) async -> DashboardAPIData?
    {
        let cookieHeader = await self.chatGPTCookieHeader(in: websiteDataStore)
        return await self.fetchDashboardUsageAPI(cookieHeader: cookieHeader, logger: logger)
    }

    private static func fetchDashboardUsageAPI(
        cookieHeader: String,
        logger: @escaping (String) -> Void) async -> DashboardAPIData?
    {
        guard !cookieHeader.isEmpty else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(
                for: self.dashboardUsageAPIRequest(cookieHeader: cookieHeader))
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger("usage api status=\(status)")
            guard status >= 200, status < 300 else { return nil }
            let decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            let result = self.dashboardAPIData(from: decoded)
            if result.hasUsageData {
                logger("usage api supplied language-independent rate/credit data")
            }
            return result
        } catch {
            logger("usage api unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private static func fetchSignedInEmailFromAPI(
        cookieHeader: String,
        logger: @escaping (String) -> Void) async -> String?
    {
        guard !cookieHeader.isEmpty else { return nil }

        let endpoints = [
            URL(string: "https://chatgpt.com/backend-api/me"),
            URL(string: "https://chatgpt.com/api/auth/session"),
        ].compactMap(\.self)

        for url in endpoints {
            do {
                let (data, response) = try await URLSession.shared.data(
                    for: self.dashboardIdentityAPIRequest(url: url, cookieHeader: cookieHeader))
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger("identity api \(url.path) status=\(status)")
                guard status >= 200, status < 300 else { continue }
                if let email = self.findFirstEmail(inJSONData: data) {
                    return email.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                logger("identity api \(url.path) unavailable: \(error.localizedDescription)")
            }
        }

        return nil
    }

    private static func chatGPTCookieHeader(in store: WKWebsiteDataStore) async -> String {
        let cookies = await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }

        return cookies
            .filter { $0.domain.lowercased().contains("chatgpt.com") }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    nonisolated static func findFirstEmail(inJSONData data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        var queue: [Any] = [json]
        var seen = 0
        while !queue.isEmpty, seen < 2000 {
            let current = queue.removeFirst()
            seen += 1
            if let string = current as? String, string.contains("@") {
                return string
            }
            if let dictionary = current as? [String: Any] {
                for (key, value) in dictionary {
                    if key.lowercased() == "email",
                       let string = value as? String,
                       string.contains("@")
                    {
                        return string
                    }
                    queue.append(value)
                }
            } else if let array = current as? [Any] {
                queue.append(contentsOf: array)
            }
        }
        return nil
    }

    private nonisolated static func rateWindow(from window: CodexUsageResponse.WindowSnapshot?) -> RateWindow? {
        guard let window else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(window.resetAt))
        return RateWindow(
            usedPercent: Double(window.usedPercent),
            windowMinutes: window.limitWindowSeconds / 60,
            resetsAt: resetDate,
            resetDescription: UsageFormatter.resetDescription(from: resetDate))
    }

    private nonisolated static func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed?.isEmpty == false { return trimmed }
        }
        return nil
    }

    private static func writeDebugArtifacts(html: String, bodyText: String?, logger: (String) -> Void) {
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let htmlURL = dir.appendingPathComponent("codex-openai-dashboard-\(stamp).html")
        do {
            try html.write(to: htmlURL, atomically: true, encoding: .utf8)
            logger("Dumped HTML: \(htmlURL.path)")
        } catch {
            logger("Failed to dump HTML: \(error.localizedDescription)")
        }

        if let bodyText, !bodyText.isEmpty {
            let textURL = dir.appendingPathComponent("codex-openai-dashboard-\(stamp).txt")
            do {
                try bodyText.write(to: textURL, atomically: true, encoding: .utf8)
                logger("Dumped text: \(textURL.path)")
            } catch {
                logger("Failed to dump text: \(error.localizedDescription)")
            }
        }
    }
}

extension OpenAIDashboardFetcher {
    struct CreditsHistoryWaitContext {
        let now: Date
        let anyDashboardSignalAt: Date?
        let creditsHeaderVisibleAt: Date?
        let creditsHeaderPresent: Bool
        let creditsHeaderInViewport: Bool
        let didScrollToCredits: Bool
    }

    nonisolated static func shouldWaitForCreditsHistory(_ context: CreditsHistoryWaitContext) -> Bool {
        if context.didScrollToCredits { return true }

        // When the header is visible but rows are still empty, wait briefly for the table to render.
        if context.creditsHeaderPresent, context.creditsHeaderInViewport {
            if let creditsHeaderVisibleAt = context.creditsHeaderVisibleAt {
                return context.now.timeIntervalSince(creditsHeaderVisibleAt) < 2.5
            }
            return true
        }

        // Header not in view yet: allow a short grace period after we first detect any dashboard signal so
        // a scroll (or hydration) can bring the credits section into the DOM.
        if let anyDashboardSignalAt = context.anyDashboardSignalAt {
            return context.now.timeIntervalSince(anyDashboardSignalAt) < 6.5
        }
        return false
    }

    struct ProbeReadinessContext {
        let now: Date
        let usageRouteSeenAt: Date?
        let dashboardSignalSeenAt: Date?
        let signedInEmail: String?
        let hasDashboardSignal: Bool
    }

    struct UsageBreakdownRecoveryContext {
        let now: Date
        let errorFirstSeenAt: Date?
    }

    nonisolated static func shouldWaitForUsageBreakdownRecovery(_ context: UsageBreakdownRecoveryContext) -> Bool {
        guard let errorFirstSeenAt = context.errorFirstSeenAt else { return true }
        return context.now.timeIntervalSince(errorFirstSeenAt) < 4.0
    }

    nonisolated static func shouldWaitForProbeReadiness(_ context: ProbeReadinessContext) -> Bool {
        if let signedInEmail = context.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !signedInEmail.isEmpty
        {
            return false
        }

        if context.hasDashboardSignal {
            if let dashboardSignalSeenAt = context.dashboardSignalSeenAt {
                return context.now.timeIntervalSince(dashboardSignalSeenAt) < 2.0
            }
            return true
        }

        if let usageRouteSeenAt = context.usageRouteSeenAt {
            return context.now.timeIntervalSince(usageRouteSeenAt) < 2.0
        }

        return false
    }

    nonisolated static func updateUsageBreakdownErrorState(
        usageBreakdown: [OpenAIDashboardDailyBreakdown],
        error: String?,
        firstSeenAt: inout Date?,
        lastError: inout String?,
        now: Date = Date(),
        logger: (String) -> Void)
    {
        guard usageBreakdown.isEmpty, let error, !error.isEmpty else {
            firstSeenAt = nil
            return
        }
        if firstSeenAt == nil { firstSeenAt = now }
        guard error != lastError else { return }
        lastError = error
        logger("usage breakdown error: \(error)")
    }
}
#else
import Foundation

@MainActor
public struct OpenAIDashboardFetcher {
    public enum FetchError: LocalizedError {
        case loginRequired
        case noDashboardData(body: String)

        public var errorDescription: String? {
            switch self {
            case .loginRequired:
                "OpenAI web access requires login."
            case let .noDashboardData(body):
                "OpenAI dashboard data not found. Body sample: \(body.prefix(200))"
            }
        }
    }

    public init() {}

    public func loadLatestDashboard(
        accountEmail _: String?,
        logger _: ((String) -> Void)? = nil,
        debugDumpHTML _: Bool = false,
        timeout _: TimeInterval = 60) async throws -> OpenAIDashboardSnapshot
    {
        throw FetchError.noDashboardData(body: "OpenAI web dashboard fetch is only supported on macOS.")
    }
}
#endif
