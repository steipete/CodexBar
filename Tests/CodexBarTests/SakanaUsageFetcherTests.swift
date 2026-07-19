import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct SakanaUsageFetcherTests {
    @Test
    func `billing html maps five hour and weekly windows`() throws {
        let now = Date(timeIntervalSince1970: 1_782_222_000)
        let usage = try SakanaUsageFetcher.parseBillingHTML(
            Self.billingHTML,
            now: now).toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 92)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == Self.date(year: 2026, month: 6, day: 23, hour: 14, minute: 53))
        #expect(usage.primary?.resetDescription == nil)
        #expect(usage.secondary?.usedPercent == 32)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.resetsAt == Self.date(year: 2026, month: 6, day: 29, hour: 0, minute: 0))
        #expect(usage.secondary?.resetDescription == nil)
        #expect(usage.identity?.providerID == .sakana)
        #expect(usage.identity?.loginMethod == "Standard $20/mo")
        #expect(usage.updatedAt == now)
    }

    @Test
    func `fetch sends normalized cookie header to billing endpoint`() async throws {
        let transport = SakanaScriptedTransport(statusCode: 200, body: Self.billingHTML)

        let snapshot = try await SakanaUsageFetcher.fetchUsage(
            cookieHeader: "Cookie: session=abc; theme=dark",
            session: transport,
            now: Date(timeIntervalSince1970: 0))
        let requests = await transport.capturedRequestsSnapshot()
        let request = requests.first { $0.url == "https://console.sakana.ai/billing" }

        #expect(snapshot.fiveHour?.usedPercent == 92)
        #expect(request?.url == "https://console.sakana.ai/billing")
        #expect(request?.method == "GET")
        #expect(request?.cookie == "session=abc; theme=dark")
        #expect(request?.acceptLanguage == "en-US,en;q=0.9")
    }

    @Test
    func `fetches pay as you go concurrently and merges the credit balance`() async throws {
        let transport = SakanaScriptedTransport(
            statusCode: 200,
            body: Self.billingHTML,
            overridesByURL: [
                "https://console.sakana.ai/billing?tab=payAsYouGo": (200, Self.payAsYouGoHTML),
            ],
            billingWaitsForPayAsYouGo: true)

        let snapshot = try await SakanaUsageFetcher.fetchUsage(
            cookieHeader: "session=abc",
            session: transport,
            now: Date(timeIntervalSince1970: 0))
        let requests = await transport.capturedRequestsSnapshot()

        #expect(snapshot.fiveHour?.usedPercent == 92)
        #expect(snapshot.payAsYouGo?.creditBalance == 12.34)
        #expect(snapshot.payAsYouGo?.periodUsageTotal == 5.67)
        #expect(snapshot.payAsYouGo?.periodLabel == "Jun 02, 2026 - Jul 01, 2026")
        #expect(requests.count == 2)
        let payAsYouGoRequest = requests.first { $0.url == "https://console.sakana.ai/billing?tab=payAsYouGo" }
        #expect(payAsYouGoRequest?.cookie == "session=abc")

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.sakanaPayAsYouGo?.balanceDetail == "$12.34")
    }

    @Test
    func `quick pay as you go response can finish after primary within the shared budget`() async throws {
        let transport = SakanaScriptedTransport(
            statusCode: 200,
            body: Self.billingHTML,
            overridesByURL: [
                "https://console.sakana.ai/billing?tab=payAsYouGo": (200, Self.payAsYouGoHTML),
            ],
            payAsYouGoDelay: .milliseconds(20))

        let snapshot = try await SakanaUsageFetcher.fetchUsage(
            cookieHeader: "session=abc",
            session: transport,
            now: Date(timeIntervalSince1970: 0))

        #expect(snapshot.fiveHour?.usedPercent == 92)
        #expect(snapshot.payAsYouGo?.creditBalance == 12.34)
    }

    @Test
    func `fetch skips the pay as you go request entirely when optional usage is disabled`() async throws {
        let transport = SakanaScriptedTransport(
            statusCode: 200,
            body: Self.billingHTML,
            overridesByURL: [
                "https://console.sakana.ai/billing?tab=payAsYouGo": (200, Self.payAsYouGoHTML),
            ])

        let snapshot = try await SakanaUsageFetcher.fetchUsage(
            cookieHeader: "session=abc",
            session: transport,
            now: Date(timeIntervalSince1970: 0),
            includeOptionalUsage: false)
        let requests = await transport.capturedRequestsSnapshot()

        #expect(snapshot.fiveHour?.usedPercent == 92)
        #expect(snapshot.payAsYouGo == nil)
        // Only the required subscription-quota request is made; disabling optional usage must not
        // just discard the PAYG result, it must skip the network request entirely.
        #expect(requests.count == 1)
        #expect(requests.first?.url == "https://console.sakana.ai/billing")
    }

    @Test
    func `pay as you go bounded fetch does not wait for an operation that ignores cancellation`() async throws {
        let startedAt = ContinuousClock.now

        let fetched = await SakanaUsageFetcher._boundedFetchPayAsYouGoForTesting(timeout: .milliseconds(20)) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    continuation.resume(returning: SakanaPayAsYouGoSnapshot(creditBalance: 9))
                }
            }
        }

        let elapsed = startedAt.duration(to: .now)
        #expect(fetched == nil)
        #expect(elapsed < .milliseconds(300))

        try await Task.sleep(for: .milliseconds(550))
    }

    @Test
    func `fetch tolerates a failing pay as you go request without failing the primary fetch`() async throws {
        // Default response is a 500; only the primary billing URL is overridden to succeed, so the
        // pay-as-you-go request (not present in the override map) falls through to that failure.
        let transport = SakanaScriptedTransport(
            statusCode: 500,
            body: "boom",
            overridesByURL: [
                "https://console.sakana.ai/billing": (200, Self.billingHTML),
            ])

        let snapshot = try await SakanaUsageFetcher.fetchUsage(
            cookieHeader: "session=abc",
            session: transport,
            now: Date(timeIntervalSince1970: 0))

        #expect(snapshot.fiveHour?.usedPercent == 92)
        #expect(snapshot.payAsYouGo == nil)
    }

    @Test
    func `slow pay as you go request never delays the primary quota result`() async throws {
        let transport = SakanaScriptedTransport(
            statusCode: 200,
            body: Self.billingHTML,
            billingWaitsForPayAsYouGo: true,
            payAsYouGoBlocksUntilCancelled: true)
        let startedAt = ContinuousClock.now

        let snapshot = try await SakanaUsageFetcher.fetchUsage(
            cookieHeader: "session=abc",
            session: transport,
            now: Date(timeIntervalSince1970: 0))

        #expect(snapshot.fiveHour?.usedPercent == 92)
        #expect(snapshot.payAsYouGo == nil)
        #expect(startedAt.duration(to: .now) < .milliseconds(500))
        for _ in 0..<1000 where await !(transport.didCancelPayAsYouGo()) {
            await Task.yield()
        }
        #expect(await transport.didCancelPayAsYouGo())
    }

    @Test
    func `required fetch failure cancels the concurrent pay as you go request`() async throws {
        let transport = SakanaScriptedTransport(
            statusCode: 401,
            body: "expired",
            billingWaitsForPayAsYouGo: true,
            payAsYouGoBlocksUntilCancelled: true)

        await #expect(throws: SakanaUsageError.loginRequired) {
            _ = try await SakanaUsageFetcher.fetchUsage(
                cookieHeader: "session=expired",
                session: transport)
        }

        for _ in 0..<1000 where await !(transport.didCancelPayAsYouGo()) {
            await Task.yield()
        }
        #expect(await transport.didCancelPayAsYouGo())
    }

    @Test
    func `fetch rejects cross origin login redirect`() async throws {
        let transport = try SakanaScriptedTransport(
            statusCode: 200,
            body: Self.billingHTML,
            responseURL: #require(URL(string: "https://auth.sakana.ai")?.appending(path: "login")))

        await #expect(throws: SakanaUsageError.loginRequired) {
            _ = try await SakanaUsageFetcher.fetchUsage(
                cookieHeader: "session=expired",
                session: transport)
        }
    }

    @Test
    func `fetch classifies blocked login redirect as login required`() async throws {
        let transport = try SakanaScriptedTransport(
            statusCode: 302,
            body: "",
            headers: ["Location": #require(URL(string: "https://auth.sakana.ai/login")).absoluteString])

        await #expect(throws: SakanaUsageError.loginRequired) {
            _ = try await SakanaUsageFetcher.fetchUsage(
                cookieHeader: "session=expired",
                session: transport)
        }
    }

    @Test
    func `fetch does not expose error response body`() async {
        let transport = SakanaScriptedTransport(statusCode: 500, body: "private account response")

        await #expect(throws: SakanaUsageError.apiError(500)) {
            _ = try await SakanaUsageFetcher.fetchUsage(
                cookieHeader: "session=abc",
                session: transport)
        }
    }

    @Test
    func `missing usage windows throws parse error`() {
        #expect(throws: SakanaUsageError.parseFailed("Usage limit windows were not found.")) {
            _ = try SakanaUsageFetcher.parseBillingHTML("<main>Billing</main>")
        }
    }

    @Test
    func `out of range percentages are rejected`() {
        let html = Self.billingHTML
            .replacing("92% used", with: "101% used")
            .replacing("32% used", with: "999% used")

        #expect(throws: SakanaUsageError.parseFailed("Invalid 5-hour usage percentage.")) {
            _ = try SakanaUsageFetcher.parseBillingHTML(html)
        }
    }

    @Test
    func `invalid primary percentage rejects otherwise valid weekly response`() {
        let html = Self.billingHTML.replacing("92% used", with: "101% used")

        #expect(throws: SakanaUsageError.parseFailed("Invalid 5-hour usage percentage.")) {
            _ = try SakanaUsageFetcher.parseBillingHTML(html)
        }
    }

    @Test
    func `unparsed reset date does not become reset description`() throws {
        let usage = try SakanaUsageFetcher.parseBillingHTML(
            Self.billingHTML.replacing("June 23, 2026 at 2:53 PM", with: "soon-ish")).toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 92)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.resetDescription == nil)
    }

    @Test
    func `window without reset line still maps percent`() throws {
        let html = Self.billingHTML.replacing(
            "<p class=\"text-muted-foreground text-xs tabular-nums\">Resets on June 23, 2026 at 2:53 PM</p>",
            with: "")
        let usage = try SakanaUsageFetcher.parseBillingHTML(html).toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 92)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.resetDescription == nil)
        #expect(usage.secondary?.usedPercent == 32)
        #expect(usage.secondary?.resetsAt == Self.date(year: 2026, month: 6, day: 29, hour: 0, minute: 0))
    }

    @Test
    func `missing window percent rejects response without reading next quota window`() {
        let html = Self.billingHTML.replacing(
            "<p class=\"text-muted-foreground text-sm\">92% used</p>",
            with: "")

        #expect(throws: SakanaUsageError.parseFailed("Invalid 5-hour usage percentage.")) {
            _ = try SakanaUsageFetcher.parseBillingHTML(html)
        }
    }

    @Test
    func `reset date is parsed as UTC regardless of the device's local timezone`() throws {
        // The console always server-renders "Resets on <date>" in UTC (the client corrects it to
        // the viewer's local time only after JS hydration, which this HTML-only fetcher never
        // runs). Regression coverage for steipete/CodexBar#1826: force the process default far
        // from UTC (UTC+14) so this fails if TimeZone.current ever leaks back into the parser --
        // on a UTC CI runner the pre-fix TimeZone.current code would coincidentally still produce
        // the right answer, so this test would not have caught the original bug without the
        // override.
        let originalTimeZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(secondsFromGMT: 14 * 60 * 60)!
        defer { NSTimeZone.default = originalTimeZone }

        let usage = try SakanaUsageFetcher.parseBillingHTML(Self.billingHTML).toUsageSnapshot()

        #expect(usage.primary?.resetsAt == Self.date(year: 2026, month: 6, day: 23, hour: 14, minute: 53))
        #expect(usage.primary?.resetsAt?.timeIntervalSince1970 == 1_782_226_380)
    }

    @Test
    func `pay as you go html maps credit balance usage total and date range label`() {
        let usage = SakanaUsageFetcher.parsePayAsYouGoHTML(Self.payAsYouGoHTML)

        #expect(usage?.creditBalance == 12.34)
        #expect(usage?.periodUsageTotal == 5.67)
        #expect(usage?.periodLabel == "Jun 02, 2026 - Jul 01, 2026")
        #expect(usage?.balanceDetail == "$12.34")
    }

    @Test
    func `pay as you go html without usage total still maps credit balance`() {
        let html = Self.payAsYouGoHTML.replacing(
            "<span class=\"text-muted-foreground text-sm\">Total<!-- -->: <!-- -->$5.67</span>",
            with: "")

        let usage = SakanaUsageFetcher.parsePayAsYouGoHTML(html)

        #expect(usage?.creditBalance == 12.34)
        #expect(usage?.periodUsageTotal == nil)
    }

    @Test
    func `billing html without a pay as you go tab returns nil`() {
        #expect(SakanaUsageFetcher.parsePayAsYouGoHTML(Self.billingHTML) == nil)
    }

    @Test
    func `sakana usage snapshot carries pay as you go through to the usage snapshot mapping`() {
        let payAsYouGo = SakanaPayAsYouGoSnapshot(creditBalance: 9, periodUsageTotal: 1.5, periodLabel: "Last 30 days")
        let snapshot = SakanaUsageSnapshot(
            planName: "Standard",
            priceLabel: "$20/mo",
            fiveHour: .init(usedPercent: 10, resetsAt: nil),
            weekly: .init(usedPercent: 20, resetsAt: nil),
            payAsYouGo: payAsYouGo)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.sakanaPayAsYouGo?.creditBalance == 9)
        #expect(usage.sakanaPayAsYouGo?.balanceDetail == "$9.00")
    }

    private static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute))
    }

    /// Raw server response values are UTC; browser hydration localizes them afterward.
    private static let billingHTML = """
    <main>
      <div data-slot="card-title"><span>Standard</span><span>$20/mo</span></div>
      <div data-slot="card-title">Usage limit</div>
      <p class="font-medium text-sm">5-hour</p>
      <p class="text-muted-foreground text-xs tabular-nums">Resets on June 23, 2026 at 2:53 PM</p>
      <button aria-label="The 5-hour window starts with your first request."></button>
      <p class="text-muted-foreground text-sm">92% used</p>
      <p class="font-medium text-sm">Weekly</p>
      <p class="text-muted-foreground text-xs tabular-nums">Resets on June 29, 2026 at 12:00 AM</p>
      <button aria-label="Weekly usage resets every Monday at 00:00 UTC."></button>
      <p class="text-muted-foreground text-sm">32% used</p>
    </main>
    """

    /// Minimal reproduction of the "Pay as you go" tab, which the live console only server-renders
    /// when the request includes `?tab=payAsYouGo`. The `<!-- -->` markers reproduce React's
    /// hydration-boundary comments between separately interpolated JSX text nodes.
    private static let payAsYouGoHTML = """
    <main>
      <h2 class="font-semibold text-base">Credit balance</h2>
      <button aria-label="Credit updates may be delayed."></button>
      <p class="font-semibold text-3xl tabular-nums">$12.34</p>
      <button aria-label="Usage date range">Jun 02, 2026<!-- --> -<!-- --> <!-- -->Jul 01, 2026</button>
      <h2 class="font-semibold">Usage</h2>
      <span class="text-muted-foreground text-sm">Total<!-- -->: <!-- -->$5.67</span>
    </main>
    """
}

private actor SakanaScriptedTransport: ProviderHTTPTransport {
    struct CapturedRequest {
        let url: String?
        let method: String?
        let cookie: String?
        let acceptLanguage: String?
    }

    private let statusCode: Int
    private let body: String
    private let responseURL: URL?
    private let headers: [String: String]
    /// Per-URL response overrides (keyed by the full request URL string), used to stub the
    /// subscription-tab and pay-as-you-go-tab requests independently. Falls back to
    /// `(statusCode, body)` for any URL not present here.
    private let overridesByURL: [String: (statusCode: Int, body: String)]
    private let billingWaitsForPayAsYouGo: Bool
    private let payAsYouGoBlocksUntilCancelled: Bool
    private let payAsYouGoDelay: Duration?
    private var capturedRequests: [CapturedRequest] = []
    private var payAsYouGoStarted = false
    private var payAsYouGoCompleted = false
    private var payAsYouGoWasCancelled = false
    private var payAsYouGoStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var payAsYouGoCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        statusCode: Int,
        body: String,
        responseURL: URL? = nil,
        headers: [String: String] = [:],
        overridesByURL: [String: (statusCode: Int, body: String)] = [:],
        billingWaitsForPayAsYouGo: Bool = false,
        payAsYouGoBlocksUntilCancelled: Bool = false,
        payAsYouGoDelay: Duration? = nil)
    {
        self.statusCode = statusCode
        self.body = body
        self.responseURL = responseURL
        self.headers = headers
        self.overridesByURL = overridesByURL
        self.billingWaitsForPayAsYouGo = billingWaitsForPayAsYouGo
        self.payAsYouGoBlocksUntilCancelled = payAsYouGoBlocksUntilCancelled
        self.payAsYouGoDelay = payAsYouGoDelay
    }

    func lastCapturedRequest() -> CapturedRequest? {
        self.capturedRequests.last
    }

    func capturedRequestsSnapshot() -> [CapturedRequest] {
        self.capturedRequests
    }

    func didCancelPayAsYouGo() -> Bool {
        self.payAsYouGoWasCancelled
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let isPayAsYouGo = request.url?.query == "tab=payAsYouGo"
        if isPayAsYouGo {
            self.markPayAsYouGoStarted()
            if let payAsYouGoDelay {
                try await Task.sleep(for: payAsYouGoDelay)
            }
            if self.payAsYouGoBlocksUntilCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    self.payAsYouGoWasCancelled = true
                    throw error
                }
            }
        } else if self.billingWaitsForPayAsYouGo {
            await self.waitForPayAsYouGoStart()
            if !self.payAsYouGoBlocksUntilCancelled {
                await self.waitForPayAsYouGoCompletion()
            }
        }

        self.capturedRequests.append(CapturedRequest(
            url: request.url?.absoluteString,
            method: request.httpMethod,
            cookie: request.value(forHTTPHeaderField: "Cookie"),
            acceptLanguage: request.value(forHTTPHeaderField: "Accept-Language")))

        let override = request.url.flatMap { self.overridesByURL[$0.absoluteString] }
        let (responseStatusCode, responseBody) = override ?? (self.statusCode, self.body)
        let response = HTTPURLResponse(
            url: self.responseURL ?? request.url!,
            statusCode: responseStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: self.headers)!
        if isPayAsYouGo {
            self.markPayAsYouGoCompleted()
        }
        return (Data(responseBody.utf8), response)
    }

    private func waitForPayAsYouGoStart() async {
        guard !self.payAsYouGoStarted else { return }
        await withCheckedContinuation { continuation in
            self.payAsYouGoStartWaiters.append(continuation)
        }
    }

    private func waitForPayAsYouGoCompletion() async {
        guard !self.payAsYouGoCompleted else { return }
        await withCheckedContinuation { continuation in
            self.payAsYouGoCompletionWaiters.append(continuation)
        }
    }

    private func markPayAsYouGoStarted() {
        self.payAsYouGoStarted = true
        let waiters = self.payAsYouGoStartWaiters
        self.payAsYouGoStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func markPayAsYouGoCompleted() {
        self.payAsYouGoCompleted = true
        let waiters = self.payAsYouGoCompletionWaiters
        self.payAsYouGoCompletionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
