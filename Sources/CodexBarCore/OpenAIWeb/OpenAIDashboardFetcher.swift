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

    let usageURL = URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage")!
    private nonisolated static let dashboardAcceptLanguage = "en-US,en;q=0.9"
    private nonisolated static let dashboardUsageAPIURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private nonisolated static let dashboardSubscriptionAPIURL =
        URL(string: "https://chatgpt.com/backend-api/subscriptions")!

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

    struct DashboardSnapshotComponents {
        let signedInEmail: String?
        let scrape: ScrapeResult
        let codeReview: Double?
        let codeReviewLimit: RateWindow?
        let events: [CreditEvent]
        let breakdown: [OpenAIDashboardDailyBreakdown]
        let usageBreakdown: [OpenAIDashboardDailyBreakdown]
        let rateLimits: (primary: RateWindow?, secondary: RateWindow?)
        let extraRateWindows: [NamedRateWindow]
        let creditsRemaining: Double?
        let codexCreditLimit: CodexCreditLimitSnapshot?
        let accountPlan: String?
        let subscription: OpenAISubscriptionMetadata?
    }

    struct DashboardScrapeData {
        let signedInEmail: String?
        let codeReview: Double?
        let codeReviewLimit: RateWindow?
        let events: [CreditEvent]
        let breakdown: [OpenAIDashboardDailyBreakdown]
        let usageBreakdown: [OpenAIDashboardDailyBreakdown]
        let rateLimits: (primary: RateWindow?, secondary: RateWindow?)
        let extraRateWindows: [NamedRateWindow]
        let creditsRemaining: Double?
        let codexCreditLimit: CodexCreditLimitSnapshot?
        let accountPlan: String?
        let hasDashboardPageSignal: Bool
        let hasReturnableData: Bool
    }

    nonisolated static func makeDashboardSnapshot(_ components: DashboardSnapshotComponents)
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
            extraRateWindows: components.extraRateWindows.isEmpty ? nil : components.extraRateWindows,
            creditsRemaining: components.creditsRemaining,
            codexCreditLimit: components.codexCreditLimit,
            accountPlan: components.accountPlan,
            subscriptionExpiresAt: components.subscription?.expiresAt,
            subscriptionRenewsAt: components.subscription?.renewsAt,
            updatedAt: Date())
    }

    static func parseDashboardScrape(
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
        let codexCreditLimit = apiData?.codexCreditLimit
        let accountPlan = scrape.accountPlan ?? apiData?.accountPlan
        let hasParsedUsageLimits = parsedRateLimits.primary != nil || parsedRateLimits.secondary != nil
        let hasUsageLimits = rateLimits.primary != nil || rateLimits.secondary != nil
        let hasDashboardPageData = self.hasReturnableDashboardData(.init(
            codeReview: codeReview,
            events: events,
            usageBreakdown: usageBreakdown,
            hasUsageLimits: hasParsedUsageLimits,
            creditsRemaining: parsedCreditsRemaining,
            codexCreditLimit: nil))
        let hasReturnableData = self.hasReturnableDashboardData(.init(
            codeReview: codeReview,
            events: events,
            usageBreakdown: usageBreakdown,
            hasUsageLimits: hasUsageLimits,
            creditsRemaining: creditsRemaining,
            codexCreditLimit: codexCreditLimit))

        // Codex `additional_rate_limits` (e.g. Codex Spark) only ship over the JSON usage API, so the
        // dashboard HTML scrape never contributes here; we just forward what the apiData decoded.
        let extraRateWindows = apiData?.extraRateWindows ?? []
        return DashboardScrapeData(
            signedInEmail: self.firstNonEmpty(scrape.signedInEmail, verifiedSignedInEmail),
            codeReview: codeReview,
            codeReviewLimit: codeReviewLimit,
            events: events,
            breakdown: breakdown,
            usageBreakdown: usageBreakdown,
            rateLimits: rateLimits,
            extraRateWindows: extraRateWindows,
            creditsRemaining: creditsRemaining,
            codexCreditLimit: codexCreditLimit,
            accountPlan: accountPlan,
            hasDashboardPageSignal: self.hasAnyDashboardSignal(
                hasReturnableData: hasDashboardPageData,
                creditsHeaderPresent: scrape.creditsHeaderPresent),
            hasReturnableData: hasReturnableData)
    }

    struct DashboardAPIData {
        let primaryLimit: RateWindow?
        let secondaryLimit: RateWindow?
        let extraRateWindows: [NamedRateWindow]
        let creditsRemaining: Double?
        let codexCreditLimit: CodexCreditLimitSnapshot?
        let accountPlan: String?

        var hasUsageData: Bool {
            self.primaryLimit != nil
                || self.secondaryLimit != nil
                || self.creditsRemaining != nil
                || self.codexCreditLimit != nil
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

    nonisolated static func sleepForDashboardPoll(_ duration: Duration) async throws {
        try? await Task.sleep(for: duration)
        try Task.checkCancellation()
    }

    public func loadLatestDashboard(
        accountEmail: String?,
        cacheScope: CookieHeaderCache.Scope? = nil,
        logger: ((String) -> Void)? = nil,
        debugDumpHTML: Bool = false,
        allowNavigationTimeoutRetry: Bool = true,
        timeout: TimeInterval = 60,
        previousSnapshot: OpenAIDashboardSnapshot? = nil,
        allowPageScrape: Bool = true) async throws -> OpenAIDashboardSnapshot
    {
        let store = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: accountEmail, scope: cacheScope)
        return try await self.loadLatestDashboard(
            websiteDataStore: store,
            logger: logger,
            debugDumpHTML: debugDumpHTML,
            allowNavigationTimeoutRetry: allowNavigationTimeoutRetry,
            timeout: timeout,
            previousSnapshot: previousSnapshot,
            allowPageScrape: allowPageScrape)
    }

    public func loadLatestDashboard(
        websiteDataStore: WKWebsiteDataStore,
        logger: ((String) -> Void)? = nil,
        debugDumpHTML: Bool = false,
        allowNavigationTimeoutRetry: Bool = true,
        timeout: TimeInterval = 60,
        previousSnapshot: OpenAIDashboardSnapshot? = nil,
        allowPageScrape: Bool = true) async throws -> OpenAIDashboardSnapshot
    {
        let startedAt = Date()
        let deadline = Self.deadline(startingAt: startedAt, timeout: timeout)
        let logLine: (String) -> Void = { logger?($0) }
        logLine("dashboard phase=api_preflight")
        let preflight = try await Self.fetchDashboardAPIPreflight(
            websiteDataStore: websiteDataStore,
            deadline: deadline,
            logger: logLine)
        try Task.checkCancellation()
        let (apiData, verifiedSignedInEmail) =
            (preflight.apiData, preflight.verifiedSignedInEmail)
        logLine("dashboard phase=api_preflight_done elapsed=\(Self.phaseElapsed(since: startedAt))")

        if Self.shouldSkipPageScrape(allowPageScrape: allowPageScrape) {
            if let apiData, apiData.hasUsageData, let verifiedSignedInEmail {
                logLine("usage api supplied verified dashboard data; skipping WebView")
                return Self.snapshotByMergingAPI(
                    apiData: apiData,
                    verifiedEmail: verifiedSignedInEmail,
                    previous: previousSnapshot)
            }
            if let previousSnapshot {
                logLine("page scrape disabled; returning previous dashboard snapshot")
                return previousSnapshot
            }
            throw FetchError.noDashboardData(body: "OpenAI dashboard APIs unavailable and page scrape disabled.")
        }

        let remainingTimeout = try Self.requiredRemainingTimeout(until: deadline)
        logLine("dashboard phase=webview_acquire")
        let lease = try await self.makeWebView(
            websiteDataStore: websiteDataStore,
            logger: logger,
            timeout: remainingTimeout,
            allowNavigationTimeoutRetry: allowNavigationTimeoutRetry)
        defer {
            lease.setPreserveLoadedPageOnRelease(false)
            lease.release()
            logLine("dashboard phase=webview_released elapsed=\(Self.phaseElapsed(since: startedAt))")
        }
        logLine("dashboard phase=hydrate elapsed=\(Self.phaseElapsed(since: startedAt))")
        return try await self.collectPageSnapshot(.init(
            webView: lease.webView,
            apiData: apiData,
            verifiedSignedInEmail: verifiedSignedInEmail,
            subscriptionResult: .unavailable,
            previousSnapshot: previousSnapshot,
            deadline: deadline,
            startedAt: startedAt,
            debugDumpHTML: debugDumpHTML,
            log: lease.log))
    }

    /// Fetches optional subscription metadata independently of the dashboard result.
    /// Callers can return usage promptly, then apply this result only after re-checking
    /// account authority.
    public func clearSessionData(
        accountEmail: String?,
        cacheScope: CookieHeaderCache.Scope? = nil) async
    {
        let store = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: accountEmail, scope: cacheScope)
        OpenAIDashboardWebViewCache.shared.evict(websiteDataStore: store)
        await OpenAIDashboardWebsiteDataStore.clearStore(forAccountEmail: accountEmail, scope: cacheScope)
    }

    public static func evictAllCachedWebViews() {
        OpenAIDashboardWebViewCache.shared.evictAll()
    }

    public static func evictIdleCachedWebViews() {
        OpenAIDashboardWebViewCache.shared.evictIdle()
    }

    #if DEBUG
    public static func seedCachedWebViewsForMemoryPressureProof() {
        OpenAIDashboardWebViewCache.shared.clearAllForTesting()
        OpenAIDashboardWebViewCache.shared.cacheEntryForTesting(websiteDataStore: .nonPersistent())
        OpenAIDashboardWebViewCache.shared.cacheEntryForTesting(websiteDataStore: .nonPersistent(), isBusy: true)
    }

    public static func cachedWebViewCountForTesting() -> Int {
        OpenAIDashboardWebViewCache.shared.entryCount
    }
    #endif

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

        var lastHref: String?
        var lastEmail: String?
        var usageRouteSeenAt: Date?
        var dashboardSignalSeenAt: Date?

        while Date() < deadline {
            try Task.checkCancellation()
            let probe = try await self.probeReadiness(webView: webView)
            lastHref = probe.href ?? lastHref
            lastEmail = probe.signedInEmail ?? lastEmail

            if probe.workspacePicker {
                try await Self.sleepForDashboardPoll(.milliseconds(500))
                continue
            }

            Self.logBlockingStateIfNeeded(probe, logger: log)
            try Self.throwIfBlockingReadinessState(probe)

            if Self.shouldReloadUsageRoute(
                href: probe.href,
                loginRequired: probe.loginRequired,
                workspacePicker: probe.workspacePicker,
                cloudflareInterstitial: probe.cloudflareInterstitial)
            {
                usageRouteSeenAt = nil
                dashboardSignalSeenAt = nil
                _ = webView.load(Self.usageURLRequest(url: self.usageURL))
                try await Self.sleepForDashboardPoll(.milliseconds(500))
                continue
            }

            let normalizedEmail = probe.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if usageRouteSeenAt == nil {
                usageRouteSeenAt = Date()
            }
            if probe.hasDashboardSignal, dashboardSignalSeenAt == nil {
                dashboardSignalSeenAt = Date()
            }
            if Self.shouldWaitForProbeReadiness(.init(
                now: Date(),
                usageRouteSeenAt: usageRouteSeenAt,
                dashboardSignalSeenAt: dashboardSignalSeenAt,
                signedInEmail: normalizedEmail,
                hasDashboardSignal: probe.hasDashboardSignal))
            {
                try await Self.sleepForDashboardPoll(.milliseconds(400))
                continue
            }

            let result = ProbeResult(
                href: probe.href,
                loginRequired: probe.loginRequired,
                workspacePicker: probe.workspacePicker,
                cloudflareInterstitial: probe.cloudflareInterstitial,
                signedInEmail: normalizedEmail,
                bodyText: nil)
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
            signedInEmail: lastEmail,
            bodyText: nil)
        lease.setPreserveLoadedPageOnRelease(false)
        return result
    }

    // MARK: - JS scrape

    struct ScrapeResult {
        let loginRequired: Bool
        let workspacePicker: Bool
        let cloudflareInterstitial: Bool
        let href: String?
        let bodyText: String?
        let signedInEmail: String?
        let authStatus: String?
        let accountPlan: String?
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

    func probeReadiness(webView: WKWebView) async throws -> ReadinessProbe {
        let any = try await webView.evaluateJavaScript(openAIDashboardReadinessScript)
        guard let dict = any as? [String: Any] else {
            return ReadinessProbe(
                loginRequired: true,
                workspacePicker: false,
                cloudflareInterstitial: false,
                href: nil,
                signedInEmail: nil,
                authStatus: nil,
                creditsHeaderPresent: false,
                creditsHeaderInViewport: false,
                didScrollToCredits: false,
                rowCount: 0,
                usageBreakdownReady: false,
                hasCodeReviewSignal: false,
                hasDashboardSignal: false)
        }

        var loginRequired = (dict["loginRequired"] as? Bool) ?? false
        let authStatus = (dict["authStatus"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let authStatus, !authStatus.isEmpty, authStatus.lowercased() != "logged_in" {
            loginRequired = true
        }
        let signedInEmail = (dict["signedInEmail"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ReadinessProbe(
            loginRequired: loginRequired,
            workspacePicker: (dict["workspacePicker"] as? Bool) ?? false,
            cloudflareInterstitial: (dict["cloudflareInterstitial"] as? Bool) ?? false,
            href: dict["href"] as? String,
            signedInEmail: signedInEmail,
            authStatus: authStatus,
            creditsHeaderPresent: (dict["creditsHeaderPresent"] as? Bool) ?? false,
            creditsHeaderInViewport: (dict["creditsHeaderInViewport"] as? Bool) ?? false,
            didScrollToCredits: (dict["didScrollToCredits"] as? Bool) ?? false,
            rowCount: (dict["rowCount"] as? NSNumber)?.intValue ?? 0,
            usageBreakdownReady: (dict["usageBreakdownReady"] as? Bool) ?? false,
            hasCodeReviewSignal: (dict["hasCodeReviewSignal"] as? Bool) ?? false,
            hasDashboardSignal: (dict["hasDashboardSignal"] as? Bool) ?? false)
    }

    func scrape(webView: WKWebView) async throws -> ScrapeResult {
        let any = try await webView.evaluateJavaScript(openAIDashboardScrapeScript)
        guard let dict = any as? [String: Any] else {
            return ScrapeResult(
                loginRequired: true,
                workspacePicker: false,
                cloudflareInterstitial: false,
                href: nil,
                bodyText: nil,
                signedInEmail: nil,
                authStatus: nil,
                accountPlan: nil,
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
        signedInEmail = signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authStatus = (dict["authStatus"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountPlan = (dict["accountPlan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let authStatus, !authStatus.isEmpty, authStatus.lowercased() != "logged_in" {
            // When logged out, the SPA can render a generic landing shell without obvious auth inputs,
            // so treat it as login-required and let the caller retry cookie import.
            loginRequired = true
        }

        return ScrapeResult(
            loginRequired: loginRequired,
            workspacePicker: workspacePicker,
            cloudflareInterstitial: cloudflareInterstitial,
            href: dict["href"] as? String,
            bodyText: dict["bodyText"] as? String,
            signedInEmail: signedInEmail,
            authStatus: authStatus,
            accountPlan: accountPlan,
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

    func fetchDebugHTML(webView: WKWebView) async throws -> String? {
        try await webView.evaluateJavaScript(
            "document.documentElement ? String(document.documentElement.outerHTML || '') : ''") as? String
    }

    private func makeWebView(
        websiteDataStore: WKWebsiteDataStore,
        logger: ((String) -> Void)?,
        timeout: TimeInterval,
        allowNavigationTimeoutRetry: Bool = true,
        preserveLoadedPageOnRelease: Bool = false) async throws -> OpenAIDashboardWebViewLease
    {
        try await OpenAIDashboardWebViewCache.shared.acquire(
            websiteDataStore: websiteDataStore,
            usageURL: self.usageURL,
            logger: logger,
            navigationTimeout: timeout,
            allowTimeoutRetry: allowNavigationTimeoutRetry,
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

    nonisolated static func shouldReloadUsageRoute(
        href: String?,
        loginRequired: Bool,
        workspacePicker: Bool,
        cloudflareInterstitial: Bool) -> Bool
    {
        guard !workspacePicker, !loginRequired, !cloudflareInterstitial else { return false }
        guard let href else { return false }
        return !self.isUsageRoute(href)
    }

    nonisolated static func usageURLRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.dashboardAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        return request
    }

    nonisolated static func dashboardAPIData(from response: CodexUsageResponse) -> DashboardAPIData {
        DashboardAPIData(
            primaryLimit: self.rateWindow(from: response.rateLimit?.primaryWindow),
            secondaryLimit: self.rateWindow(from: response.rateLimit?.secondaryWindow),
            extraRateWindows: CodexAdditionalRateLimitMapper.extraRateWindows(
                from: response.additionalRateLimits),
            creditsRemaining: response.credits?.balance,
            codexCreditLimit: response.resolvedIndividualLimit?.codexCreditLimitSnapshot(updatedAt: Date()),
            accountPlan: response.planType?.rawValue)
    }

    private static func fetchDashboardAPIPreflight(
        websiteDataStore: WKWebsiteDataStore,
        deadline: Date,
        logger: @escaping (String) -> Void)
        async throws -> (
            apiData: DashboardAPIData?,
            verifiedSignedInEmail: String?)
    {
        let cookieHeader = try await self.chatGPTCookieHeader(in: websiteDataStore, deadline: deadline)
        let apiData = await self.fetchDashboardUsageAPI(
            cookieHeader: cookieHeader,
            deadline: deadline,
            logger: logger)
        let verifiedEmail: String? = if apiData?.hasUsageData == true {
            await self.fetchSignedInEmailFromAPI(
                cookieHeader: cookieHeader,
                deadline: deadline,
                logger: logger)
        } else {
            nil
        }
        if apiData?.hasUsageData == true, verifiedEmail != nil {
            logger("usage api supplied verified dashboard data")
        }
        return (apiData, verifiedEmail)
    }

    private static func fetchDashboardUsageAPI(
        websiteDataStore: WKWebsiteDataStore,
        logger: @escaping (String) -> Void) async -> DashboardAPIData?
    {
        guard let cookieHeader = try? await self.chatGPTCookieHeader(in: websiteDataStore, deadline: nil) else {
            return nil
        }
        return await self.fetchDashboardUsageAPI(cookieHeader: cookieHeader, deadline: nil, logger: logger)
    }

    static func fetchDashboardUsageAPI(
        cookieHeader: String,
        deadline: Date?,
        logger: @escaping (String) -> Void) async -> DashboardAPIData?
    {
        guard !cookieHeader.isEmpty else { return nil }
        let remaining = deadline.map { self.remainingTimeout(until: $0) } ?? 4
        guard remaining > 0 else { return nil }

        do {
            let (data, response) = try await CodexAuthenticatedHTTPTransport.current.data(
                for: self.dashboardUsageAPIRequest(cookieHeader: cookieHeader, timeout: min(4, remaining)))
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger("usage api status=\(status)")
            guard status >= 200, status < 300 else { return nil }
            let decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            let result = self.dashboardAPIData(from: decoded)
            let enrichedResult = await self.fetchSpendControlsMonthlyUsageIfNeeded(
                result,
                response: decoded,
                cookieHeader: cookieHeader,
                deadline: deadline,
                logger: logger)
            if enrichedResult.hasUsageData {
                logger("usage api supplied language-independent rate/credit data")
            }
            return enrichedResult
        } catch {
            logger("usage api unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    static func fetchSignedInEmailFromAPI(
        cookieHeader: String,
        deadline: Date?,
        logger: @escaping (String) -> Void) async -> String?
    {
        guard !cookieHeader.isEmpty else { return nil }

        let endpoints = [
            URL(string: "https://chatgpt.com/backend-api/me"),
            URL(string: "https://chatgpt.com/api/auth/session"),
        ].compactMap(\.self)

        for url in endpoints {
            let remaining = deadline.map { self.remainingTimeout(until: $0) } ?? 2
            guard remaining > 0 else { return nil }
            do {
                let (data, response) = try await CodexAuthenticatedHTTPTransport.current.data(
                    for: self.dashboardIdentityAPIRequest(
                        url: url,
                        cookieHeader: cookieHeader,
                        timeout: min(2, remaining)))
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

    static func fetchSubscriptionFromAPI(
        cookieHeader: String,
        deadline: Date?,
        logger: @escaping (String) -> Void) async -> OpenAISubscriptionFetchResult
    {
        guard !cookieHeader.isEmpty else { return .unavailable }
        let remaining = deadline.map { self.remainingTimeout(until: $0) } ?? 2
        guard remaining > 0 else { return .unavailable }

        do {
            let (data, response) = try await CodexAuthenticatedHTTPTransport.current.data(
                for: self.dashboardSubscriptionAPIRequest(
                    cookieHeader: cookieHeader,
                    timeout: min(2, remaining)))
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger("subscription api status=\(status)")
            guard status >= 200, status < 300 else { return .unavailable }
            let result = self.subscriptionMetadataResult(from: data)
            if case .success = result, result.metadata != nil {
                logger("subscription api supplied renewal data")
            } else if case .success = result {
                logger("subscription api response empty")
            } else {
                logger("subscription api response invalid")
            }
            return result
        } catch {
            logger("subscription api unavailable: \(error.localizedDescription)")
            return .unavailable
        }
    }

    nonisolated static func subscriptionMetadata(from data: Data) -> OpenAISubscriptionMetadata? {
        self.subscriptionMetadataResult(from: data).metadata
    }

    nonisolated static func subscriptionMetadataResult(from data: Data) -> OpenAISubscriptionFetchResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unavailable
        }

        let activeUntilValue = json["active_until"] ?? json["activeUntil"]
        let willRenewValue = json["will_renew"] ?? json["willRenew"]
        guard let activeUntilValue, let willRenewValue else { return .unavailable }

        let activeUntil = (activeUntilValue as? String)
        let willRenew = (willRenewValue as? Bool)
        let activeUntilIsValid = activeUntilValue is NSNull || activeUntil != nil
        let willRenewIsBoolean = (willRenewValue as? NSNumber).map {
            CFGetTypeID($0) == CFBooleanGetTypeID()
        } ?? false
        let willRenewIsValid = willRenewValue is NSNull || willRenewIsBoolean
        guard activeUntilIsValid, willRenewIsValid else { return .unavailable }

        return OpenAISubscriptionMetadata.parseResult(
            activeUntil: activeUntil,
            willRenew: willRenew,
            fieldsPresent: true)
    }

    private static func chatGPTCookieHeader(in store: WKWebsiteDataStore, deadline: Date?) async throws -> String {
        let cookies = try await OpenAIDashboardBrowserCookieImporter.runBoundedValueCallback(
            deadline: deadline)
        { completion in
            store.httpCookieStore.getAllCookies(completion)
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
            if trimmed?.isEmpty == false {
                return trimmed
            }
        }
        return nil
    }

    static func writeDebugArtifacts(html: String, bodyText: String?, logger: (String) -> Void) {
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
        if context.didScrollToCredits {
            return true
        }

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
        if firstSeenAt == nil {
            firstSeenAt = now
        }
        guard error != lastError else { return }
        lastError = error
        logger("usage breakdown error: \(error)")
    }
}

extension OpenAIDashboardFetcher {
    private static func fetchSpendControlsMonthlyUsageIfNeeded(
        _ result: DashboardAPIData,
        response: CodexUsageResponse,
        cookieHeader: String,
        deadline: Date?,
        logger: @escaping (String) -> Void) async -> DashboardAPIData
    {
        guard CodexSpendControlsMonthlyUsageGate.shouldFetch(response: response),
              let accountId = response.accountId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountId.isEmpty
        else { return result }

        let remaining = deadline.map { self.remainingTimeout(until: $0) } ?? 4
        guard remaining > 0 else {
            logger("spend controls monthly usage api unavailable: request deadline expired")
            return result
        }
        guard let request = self.dashboardSpendControlsMonthlyUsageAPIRequest(
            accountId: accountId,
            cookieHeader: cookieHeader,
            timeout: min(4, remaining))
        else {
            logger("spend controls monthly usage api unavailable: invalid account id")
            return result
        }

        do {
            let (data, response) = try await CodexAuthenticatedHTTPTransport.current.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status >= 200, status < 300 else {
                logger("spend controls monthly usage api unavailable: status=\(status)")
                return result
            }
            let decoded = try JSONDecoder().decode(CodexSpendControlsMonthlyUsageResponse.self, from: data)
            guard let limit = decoded.codexCreditLimitSnapshot(updatedAt: Date()) else { return result }
            return DashboardAPIData(
                primaryLimit: result.primaryLimit,
                secondaryLimit: result.secondaryLimit,
                extraRateWindows: result.extraRateWindows,
                creditsRemaining: result.creditsRemaining,
                codexCreditLimit: limit,
                accountPlan: result.accountPlan)
        } catch {
            logger("spend controls monthly usage api unavailable: \(error.localizedDescription)")
            return result
        }
    }

    nonisolated static func requiredRemainingTimeout(
        until deadline: Date,
        now: Date = Date()) throws -> TimeInterval
    {
        let remaining = self.remainingTimeout(until: deadline, now: now)
        guard remaining > 0 else { throw URLError(.timedOut) }
        return remaining
    }

    nonisolated static func dashboardUsageAPIRequest(
        cookieHeader: String,
        timeout: TimeInterval = 4) -> URLRequest
    {
        var request = URLRequest(
            url: Self.dashboardUsageAPIURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.dashboardAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated static func dashboardSpendControlsMonthlyUsageAPIURL(accountId: String) -> URL? {
        var allowedCharacters = CharacterSet.urlPathAllowed
        allowedCharacters.subtract(CharacterSet(charactersIn: "/?#%"))
        guard let encodedAccountId = accountId.addingPercentEncoding(withAllowedCharacters: allowedCharacters),
              !encodedAccountId.isEmpty
        else { return nil }
        return URL(string: "https://chatgpt.com/backend-api/accounts/\(encodedAccountId)" +
            "/spend-controls/current-user/monthly-usage")
    }

    nonisolated static func dashboardSpendControlsMonthlyUsageAPIRequest(
        accountId: String,
        cookieHeader: String,
        timeout: TimeInterval = 4) -> URLRequest?
    {
        guard let url = self.dashboardSpendControlsMonthlyUsageAPIURL(accountId: accountId) else {
            return nil
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.dashboardAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated static func dashboardIdentityAPIRequest(
        url: URL,
        cookieHeader: String,
        timeout: TimeInterval = 2) -> URLRequest
    {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.dashboardAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated static func dashboardSubscriptionAPIRequest(
        cookieHeader: String,
        timeout: TimeInterval = 2) -> URLRequest
    {
        var request = URLRequest(
            url: Self.dashboardSubscriptionAPIURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.dashboardAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated static func phaseElapsed(since start: Date, now: Date = Date()) -> String {
        String(format: "%.2fs", now.timeIntervalSince(start))
    }

    static func logBlockingStateIfNeeded(_ probe: ReadinessProbe, logger: (String) -> Void) {
        guard probe.loginRequired || probe.cloudflareInterstitial else { return }
        let route = self.isUsageRoute(probe.href) ? "usage" : "other"
        logger(
            "blocking state before route reload route=\(route) " +
                "login=\(probe.loginRequired) cloudflare=\(probe.cloudflareInterstitial)")
    }

    static func throwIfBlockingReadinessState(_ probe: ReadinessProbe) throws {
        if probe.loginRequired {
            throw FetchError.loginRequired
        }
        if probe.cloudflareInterstitial {
            throw FetchError.noDashboardData(body: "Cloudflare challenge detected in WebView.")
        }
    }

    func handleBlockingReadinessState(
        _ probe: ReadinessProbe,
        webView: WKWebView,
        debugDumpHTML: Bool,
        logger: (String) -> Void) async throws
    {
        if debugDumpHTML,
           probe.loginRequired || probe.cloudflareInterstitial,
           let html = try? await self.fetchDebugHTML(webView: webView)
        {
            Self.writeDebugArtifacts(html: html, bodyText: nil, logger: logger)
        }
        Self.logBlockingStateIfNeeded(probe, logger: logger)
        try Self.throwIfBlockingReadinessState(probe)
    }
}

extension OpenAIDashboardFetcher {
    public func fetchSubscriptionMetadata(
        accountEmail: String?,
        cacheScope: CookieHeaderCache.Scope? = nil,
        logger: ((String) -> Void)? = nil,
        timeout: TimeInterval = 8) async -> OpenAISubscriptionFetchResult
    {
        guard !Task.isCancelled, timeout > 0 else { return .unavailable }
        let deadline = Self.deadline(startingAt: Date(), timeout: timeout)
        let logLine: (String) -> Void = { logger?($0) }
        let websiteDataStore = OpenAIDashboardWebsiteDataStore.store(
            forAccountEmail: accountEmail,
            scope: cacheScope)
        guard let cookieHeader = try? await Self.chatGPTCookieHeader(
            in: websiteDataStore,
            deadline: deadline)
        else {
            logLine("subscription metadata unavailable: cookies unavailable")
            return .unavailable
        }

        guard !Task.isCancelled, Date() < deadline else { return .unavailable }
        let apiResult = await Self.fetchSubscriptionFromAPI(
            cookieHeader: cookieHeader,
            deadline: min(deadline, Date().addingTimeInterval(2)),
            logger: logLine)
        guard !Task.isCancelled, Date() < deadline else { return .unavailable }
        guard !apiResult.succeeded else { return apiResult }

        do {
            let lease = try await self.makeWebView(
                websiteDataStore: websiteDataStore,
                logger: logger,
                timeout: Self.requiredRemainingTimeout(until: deadline))
            defer { lease.release() }
            logLine("subscription metadata billing fallback start after dashboard result")
            return try await (OpenAISubscription.fetch(
                lease.webView,
                deadline: deadline,
                logger: lease.log))
        } catch is CancellationError {
            return .unavailable
        } catch {
            logLine("subscription metadata unavailable: \(error.localizedDescription)")
            return .unavailable
        }
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
        cacheScope _: CookieHeaderCache.Scope? = nil,
        logger _: ((String) -> Void)? = nil,
        debugDumpHTML _: Bool = false,
        allowNavigationTimeoutRetry _: Bool = true,
        timeout _: TimeInterval = 60,
        previousSnapshot _: OpenAIDashboardSnapshot? = nil,
        allowPageScrape _: Bool = true) async throws -> OpenAIDashboardSnapshot
    {
        throw FetchError.noDashboardData(body: "OpenAI web dashboard fetch is only supported on macOS.")
    }
}
#endif
