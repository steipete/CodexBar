import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct SakanaPluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `oversized optional period text cannot discard primary quotas`(engine: ProviderPluginEngineKind) async throws {
        let payg = Self.payAsYouGoHTML.replacing(
            "Jun 02, 2026<!-- --> -<!-- --> <!-- -->Jul 01, 2026",
            with: String(repeating: "x", count: 200))
        let transport = SakanaScriptedTransport(
            statusCode: 200,
            body: Self.billingHTML,
            overridesByURL: ["https://console.sakana.ai/billing?tab=payAsYouGo": (200, payg)],
            billingWaitsForPayAsYouGo: true)
        let usage = try await Self.fetch(transport, engine: engine)
        #expect(usage.primary?.usedPercent == 92)
        #expect(usage.detailRow(label: "Usage")?.secondaryValue == String(repeating: "x", count: 120))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing HTML keeps quota windows UTC resets plan and request headers`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = SakanaScriptedTransport(statusCode: 200, body: Self.billingHTML)
        let now = Date(timeIntervalSince1970: 1_782_222_000)
        let usage = try await Self.fetch(transport, engine: engine, optional: false, now: now)
        #expect(usage.primary?.usedPercent == 92)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_782_226_380))
        #expect(usage.primary?.resetDescription == nil)
        #expect(usage.secondary?.usedPercent == 32)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.resetsAt == Date(timeIntervalSince1970: 1_782_691_200))
        #expect(usage.identity?.providerID == .sakana)
        #expect(usage.identity?.loginMethod == "Standard $20/mo")
        #expect(usage.updatedAt == now)
        let requests = await transport.capturedRequestsSnapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.url == "https://console.sakana.ai/billing")
        #expect(requests.first?.method == "GET")
        #expect(requests.first?.cookie == "session=fixture")
        #expect(requests.first?.acceptLanguage == "en-US,en;q=0.9")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `optional GET overlaps primary and produces generic balance details`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = SakanaScriptedTransport(
            statusCode: 200,
            body: Self.billingHTML,
            overridesByURL: ["https://console.sakana.ai/billing?tab=payAsYouGo": (200, Self.payAsYouGoHTML)],
            billingWaitsForPayAsYouGo: true)
        let usage = try await Self.fetch(transport, engine: engine)
        #expect(usage.primary?.usedPercent == 92)
        #expect(usage.detailRow(label: "Balance")?.value == "$12.34")
        #expect(usage.detailRow(label: "Usage")?.value == "$5.67")
        #expect(usage.detailRow(label: "Usage")?.secondaryValue == "Jun 02, 2026 - Jul 01, 2026")
        #expect(await transport.capturedRequestsSnapshot().count == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `quick optional response can arrive after primary within shared budget`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = SakanaScriptedTransport(
            statusCode: 200,
            body: Self.billingHTML,
            overridesByURL: ["https://console.sakana.ai/billing?tab=payAsYouGo": (200, Self.payAsYouGoHTML)],
            payAsYouGoDelay: .milliseconds(20))
        let usage = try await Self.fetch(transport, engine: engine)
        #expect(usage.detailRow(label: "Balance")?.value == "$12.34")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `slow optional request is cancelled without waiting for its timeout`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = SakanaScriptedTransport(
            statusCode: 200,
            body: Self.billingHTML,
            billingWaitsForPayAsYouGo: true,
            payAsYouGoBlocksUntilCancelled: true)
        let task = Task { try await Self.fetch(transport, engine: engine) }
        let usage: UsageSnapshot
        switch await BoundedTaskJoin(sourceTask: task).value(joinGrace: .seconds(10)) {
        case let .value(value): usage = value
        case .failure, .timedOut:
            Issue.record("Optional request held the primary result")
            return
        }
        #expect(usage.primary?.usedPercent == 92)
        #expect(usage.details.isEmpty)
        #expect(try await transport.waitForPayAsYouGoCancellation())
        #expect(await transport.payAsYouGoCancellationDuration() < .seconds(4))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `required HTTP failure cancels optional work and preserves login diagnosis`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = SakanaScriptedTransport(
            statusCode: 401,
            body: "expired",
            billingWaitsForPayAsYouGo: true,
            payAsYouGoBlocksUntilCancelled: true)
        await Self.expectFailure(.authenticationExpired) { try await Self.fetch(transport, engine: engine) }
        #expect(try await transport.waitForPayAsYouGoCancellation())
    }

    @Test(arguments: BundledPluginTestSupport.engines, [401, 403, 302])
    func `unauthorized and redirected primary responses require login`(
        engine: ProviderPluginEngineKind,
        status: Int) async
    {
        await Self.expectFailure(.authenticationExpired) {
            try await Self.fetch(SakanaScriptedTransport(statusCode: status, body: "private body"), engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `cross origin response is rejected even if transport reports success`(
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.authenticationExpired) {
            try await Self.fetch(
                SakanaScriptedTransport(
                    statusCode: 200,
                    body: Self.billingHTML,
                    responseURL: URL(string: "https://auth.sakana.ai/login")),
                engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `server error never exposes response body`(engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.apiFailure) {
            try await Self.fetch(SakanaScriptedTransport(statusCode: 500, body: "private body"), engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["", "<main>Billing</main>", "invalid", "missing"])
    func `empty absent invalid and missing percentages fail parsing`(
        engine: ProviderPluginEngineKind,
        shape: String) async
    {
        let html = switch shape {
        case "invalid": Self.billingHTML.replacing("92% used", with: "101% used")
        case "missing": Self.billingHTML.replacing("<p class=\"text-muted-foreground text-sm\">92% used</p>", with: "")
        default: shape
        }
        await Self.expectFailure(.parseFailure) {
            try await Self.fetch(SakanaScriptedTransport(statusCode: 200, body: html), engine: engine, optional: false)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["soon-ish", "February 31, 2026 at 2:53 PM", ""])
    func `unparseable reset dates preserve percentages without invented reset descriptions`(
        engine: ProviderPluginEngineKind,
        reset: String) async throws
    {
        let html = Self.billingHTML.replacing("June 23, 2026 at 2:53 PM", with: reset)
        let usage = try await Self.fetch(
            SakanaScriptedTransport(statusCode: 200, body: html),
            engine: engine,
            optional: false)
        #expect(usage.primary?.usedPercent == 92)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.resetDescription == nil)
        #expect(usage.secondary?.usedPercent == 32)
    }

    @Test(arguments: BundledPluginTestSupport.engines, [500, 401, 200])
    func `optional HTTP and markup failures preserve required quotas`(
        engine: ProviderPluginEngineKind,
        status: Int) async throws
    {
        let transport = SakanaScriptedTransport(
            statusCode: status,
            body: "optional failure",
            overridesByURL: ["https://console.sakana.ai/billing": (200, Self.billingHTML)])
        let usage = try await Self.fetch(transport, engine: engine)
        #expect(usage.primary?.usedPercent == 92)
        #expect(usage.details.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `balance survives absent usage total and zero remains a measured balance`(
        engine: ProviderPluginEngineKind) async throws
    {
        let payg = Self.payAsYouGoHTML.replacing("$12.34", with: "$0.00")
            .replacing("<span class=\"text-muted-foreground text-sm\">Total<!-- -->: <!-- -->$5.67</span>", with: "")
        let transport = SakanaScriptedTransport(
            statusCode: 200,
            body: Self.billingHTML,
            overridesByURL: ["https://console.sakana.ai/billing?tab=payAsYouGo": (200, payg)],
            billingWaitsForPayAsYouGo: true)
        let usage = try await Self.fetch(transport, engine: engine)
        #expect(usage.detailRow(label: "Balance")?.value == "$0.00")
        #expect(usage.detailRow(label: "Usage") == nil)
    }

    private static func fetch(
        _ transport: any ProviderHTTPTransport,
        engine: ProviderPluginEngineKind,
        optional: Bool = true,
        now: Date = Date()) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime("sakana", engine: engine, transport: transport)
        return try await runtime.fetchUsage(
            settings: ["OPTIONAL_USAGE": String(optional)],
            secrets: ["SAKANA_COOKIE": "session=fixture"],
            now: now,
            timeZone: TimeZone(secondsFromGMT: 14 * 3600)!)
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.localizedDescription.contains("private body"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
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
    private var cancellationDuration: Duration = .seconds(30)
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

    func payAsYouGoCancellationDuration() -> Duration { self.cancellationDuration }

    func waitForPayAsYouGoCancellation() async throws -> Bool {
        // Stay below the optional request's five-second fallback timeout.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !self.payAsYouGoWasCancelled, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return self.payAsYouGoWasCancelled
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let isPayAsYouGo = request.url?.query == "tab=payAsYouGo"
        if isPayAsYouGo {
            self.markPayAsYouGoStarted()
            if let payAsYouGoDelay {
                try await Task.sleep(for: payAsYouGoDelay)
            }
            if self.payAsYouGoBlocksUntilCancelled {
                let startedAt = ContinuousClock.now
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    self.cancellationDuration = startedAt.duration(to: .now)
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
