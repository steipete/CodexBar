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

    private let usageURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

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

    private nonisolated static func logDashboardEvent(
        _ message: String,
        data: [String: String])
    {
        AgentDebugLogger.log(
            message,
            hypothesisId: "J",
            location: "OpenAIDashboardFetcher.swift:loadLatestDashboard",
            data: data)
    }

    private struct DashboardFetchTrace {
        let startedAt: Date
        let timeout: TimeInterval
        var scrapeIterations = 0
        var routeReloadCount = 0
        var workspaceWaitCount = 0
        var creditsScrollWaitCount = 0
        var creditsHydrationWaitCount = 0
        var breakdownHydrationWaitCount = 0
    }

    private struct DashboardSnapshotComponents {
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

    private nonisolated static func emitDashboardSummary(
        message: String,
        trace: DashboardFetchTrace,
        anyDashboardSignalAt: Date?,
        extra: [String: String] = [:])
    {
        var data: [String: String] = [
            "durationMs": String(Int(Date().timeIntervalSince(trace.startedAt) * 1000)),
            "timeoutSeconds": String(Int(trace.timeout)),
            "iterations": String(trace.scrapeIterations),
            "routeReloads": String(trace.routeReloadCount),
            "workspaceWaits": String(trace.workspaceWaitCount),
            "creditsScrollWaits": String(trace.creditsScrollWaitCount),
            "creditsHydrationWaits": String(trace.creditsHydrationWaitCount),
            "breakdownHydrationWaits": String(trace.breakdownHydrationWaitCount),
            "hadDashboardSignal": anyDashboardSignalAt == nil ? "0" : "1",
        ]
        for (key, value) in extra {
            data[key] = value
        }
        Self.logDashboardEvent(message, data: data)
    }

    private nonisolated static func makeDashboardSnapshot(_ components: DashboardSnapshotComponents)
        -> OpenAIDashboardSnapshot
    {
        OpenAIDashboardSnapshot(
            signedInEmail: components.scrape.signedInEmail,
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

    // swiftlint:disable function_body_length
    public func loadLatestDashboard(
        websiteDataStore: WKWebsiteDataStore,
        logger: ((String) -> Void)? = nil,
        debugDumpHTML: Bool = false,
        timeout: TimeInterval = 60) async throws -> OpenAIDashboardSnapshot
    {
        var trace = DashboardFetchTrace(startedAt: Date(), timeout: timeout)
        let deadline = Self.deadline(startingAt: Date(), timeout: timeout)
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
        var lastUsageBreakdownDebug: String?
        var lastCreditsPurchaseURL: String?
        while Date() < deadline {
            trace.scrapeIterations += 1
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
                trace.workspaceWaitCount += 1
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            // The page is a SPA and can land on ChatGPT UI or other routes; keep forcing the usage URL.
            if let href = scrape.href, !Self.isUsageRoute(href) {
                trace.routeReloadCount += 1
                _ = webView.load(URLRequest(url: self.usageURL))
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }

            if scrape.loginRequired {
                if debugDumpHTML, let html = scrape.bodyHTML {
                    Self.writeDebugArtifacts(html: html, bodyText: scrape.bodyText, logger: log)
                }
                Self.emitDashboardSummary(
                    message: "0.20 OpenAI dashboard fetch returned login-required",
                    trace: trace,
                    anyDashboardSignalAt: anyDashboardSignalAt,
                    extra: [
                        "cloudflare": scrape.cloudflareInterstitial ? "1" : "0",
                        "workspacePicker": scrape.workspacePicker ? "1" : "0",
                    ])
                throw FetchError.loginRequired
            }

            if scrape.cloudflareInterstitial {
                if debugDumpHTML, let html = scrape.bodyHTML {
                    Self.writeDebugArtifacts(html: html, bodyText: scrape.bodyText, logger: log)
                }
                Self.emitDashboardSummary(
                    message: "0.20 OpenAI dashboard fetch hit Cloudflare interstitial",
                    trace: trace,
                    anyDashboardSignalAt: anyDashboardSignalAt)
                throw FetchError.noDashboardData(body: "Cloudflare challenge detected in WebView.")
            }

            let bodyText = scrape.bodyText ?? ""
            let codeReview = OpenAIDashboardParser.parseCodeReviewRemainingPercent(bodyText: bodyText)
            let events = OpenAIDashboardParser.parseCreditEvents(rows: scrape.rows)
            let breakdown = OpenAIDashboardSnapshot.makeDailyBreakdown(from: events, maxDays: 30)
            let usageBreakdown = scrape.usageBreakdown
            let rateLimits = OpenAIDashboardParser.parseRateLimits(bodyText: bodyText)
            let codeReviewLimit = OpenAIDashboardParser.parseCodeReviewLimit(bodyText: bodyText)
            let creditsRemaining = OpenAIDashboardParser.parseCreditsRemaining(bodyText: bodyText)
            let accountPlan = scrape.bodyHTML.flatMap(OpenAIDashboardParser.parsePlanFromHTML)
            let hasUsageLimits = rateLimits.primary != nil || rateLimits.secondary != nil

            if codeReview != nil, codeReviewFirstSeenAt == nil { codeReviewFirstSeenAt = Date() }
            if anyDashboardSignalAt == nil,
               codeReview != nil || !usageBreakdown.isEmpty || scrape.creditsHeaderPresent ||
               hasUsageLimits || creditsRemaining != nil
            {
                anyDashboardSignalAt = Date()
            }
            if codeReview != nil, usageBreakdown.isEmpty,
               let debug = scrape.usageBreakdownDebug, !debug.isEmpty,
               debug != lastUsageBreakdownDebug
            {
                lastUsageBreakdownDebug = debug
                log("usage breakdown debug: \(debug)")
            }
            if let purchaseURL = scrape.creditsPurchaseURL, purchaseURL != lastCreditsPurchaseURL {
                lastCreditsPurchaseURL = purchaseURL
                log("credits purchase url: \(purchaseURL)")
            }
            if events.isEmpty,
               codeReview != nil || !usageBreakdown.isEmpty || hasUsageLimits || creditsRemaining != nil
            {
                log(
                    "credits header present=\(scrape.creditsHeaderPresent) " +
                        "inViewport=\(scrape.creditsHeaderInViewport) didScroll=\(scrape.didScrollToCredits) " +
                        "rows=\(scrape.rows.count)")
                if scrape.didScrollToCredits {
                    trace.creditsScrollWaitCount += 1
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
                    trace.creditsHydrationWaitCount += 1
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }
            }

            if codeReview != nil || !events.isEmpty || !usageBreakdown
                .isEmpty || hasUsageLimits || creditsRemaining != nil
            {
                // The usage breakdown chart is hydrated asynchronously. When code review is already present,
                // give it a moment to populate so the menu can show it.
                if codeReview != nil, usageBreakdown.isEmpty {
                    let elapsed = Date().timeIntervalSince(codeReviewFirstSeenAt ?? Date())
                    if elapsed < 6 {
                        trace.breakdownHydrationWaitCount += 1
                        try? await Task.sleep(for: .milliseconds(400))
                        continue
                    }
                }
                Self.emitDashboardSummary(
                    message: "0.20 OpenAI dashboard fetch succeeded",
                    trace: trace,
                    anyDashboardSignalAt: anyDashboardSignalAt,
                    extra: [
                        "creditRows": String(events.count),
                        "usageBreakdownDays": String(usageBreakdown.count),
                        "hasRateLimits": hasUsageLimits ? "1" : "0",
                        "hasCreditsRemaining": creditsRemaining == nil ? "0" : "1",
                    ])
                return Self.makeDashboardSnapshot(.init(
                    scrape: scrape,
                    codeReview: codeReview,
                    codeReviewLimit: codeReviewLimit,
                    events: events,
                    breakdown: breakdown,
                    usageBreakdown: usageBreakdown,
                    rateLimits: rateLimits,
                    creditsRemaining: creditsRemaining,
                    accountPlan: accountPlan))
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        if debugDumpHTML, let html = lastHTML {
            Self.writeDebugArtifacts(html: html, bodyText: lastBody, logger: log)
        }
        Self.emitDashboardSummary(
            message: "0.20 OpenAI dashboard fetch exhausted timeout without data",
            trace: trace,
            anyDashboardSignalAt: anyDashboardSignalAt,
            extra: [
                "lastBodyPresent": lastBody == nil ? "0" : "1",
                "lastHrefKnown": lastHref == nil ? "0" : "1",
            ])
        throw FetchError.noDashboardData(body: lastBody ?? "")
    }

    // swiftlint:enable function_body_length

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

    public func clearSessionData(accountEmail: String?) async {
        let store = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: accountEmail)
        OpenAIDashboardWebViewCache.shared.evict(websiteDataStore: store)
        await OpenAIDashboardWebsiteDataStore.clearStore(forAccountEmail: accountEmail)
    }

    public static func evictAllCachedWebViews() {
        OpenAIDashboardWebViewCache.shared.evictAll()
    }

    public static func evictCachedWebView(accountEmail: String?) {
        let store = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: accountEmail)
        OpenAIDashboardWebViewCache.shared.evict(websiteDataStore: store)
    }

    public func probeUsagePage(
        websiteDataStore: WKWebsiteDataStore,
        logger: ((String) -> Void)? = nil,
        timeout: TimeInterval = 30) async throws -> ProbeResult
    {
        let deadline = Self.deadline(startingAt: Date(), timeout: timeout)
        let lease = try await self.makeWebView(
            websiteDataStore: websiteDataStore,
            logger: logger,
            timeout: Self.remainingTimeout(until: deadline))
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
                _ = webView.load(URLRequest(url: self.usageURL))
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

            return ProbeResult(
                href: scrape.href,
                loginRequired: scrape.loginRequired,
                workspacePicker: scrape.workspacePicker,
                cloudflareInterstitial: scrape.cloudflareInterstitial,
                signedInEmail: normalizedEmail,
                bodyText: scrape.bodyText)
        }

        log("Probe timed out (href=\(lastHref ?? "nil"))")
        return ProbeResult(
            href: lastHref,
            loginRequired: false,
            workspacePicker: false,
            cloudflareInterstitial: false,
            signedInEmail: nil,
            bodyText: lastBody)
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
        if let raw = dict["usageBreakdownJSON"] as? String, !raw.isEmpty {
            do {
                let decoder = JSONDecoder()
                usageBreakdown = try decoder.decode([OpenAIDashboardDailyBreakdown].self, from: Data(raw.utf8))
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
            scrollY: (dict["scrollY"] as? NSNumber)?.doubleValue ?? 0,
            scrollHeight: (dict["scrollHeight"] as? NSNumber)?.doubleValue ?? 0,
            viewportHeight: (dict["viewportHeight"] as? NSNumber)?.doubleValue ?? 0,
            creditsHeaderPresent: (dict["creditsHeaderPresent"] as? Bool) ?? false,
            creditsHeaderInViewport: (dict["creditsHeaderInViewport"] as? Bool) ?? false,
            didScrollToCredits: (dict["didScrollToCredits"] as? Bool) ?? false)
    }

    private func makeWebView(
        websiteDataStore: WKWebsiteDataStore,
        logger: ((String) -> Void)?,
        timeout: TimeInterval) async throws -> OpenAIDashboardWebViewLease
    {
        try await OpenAIDashboardWebViewCache.shared.acquire(
            websiteDataStore: websiteDataStore,
            usageURL: self.usageURL,
            logger: logger,
            navigationTimeout: timeout)
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
        return path.hasSuffix("codex/settings/usage") || path.hasSuffix("codex/cloud/settings/usage")
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
