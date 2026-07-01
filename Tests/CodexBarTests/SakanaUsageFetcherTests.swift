import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct SakanaUsageFetcherTests {
    @Test
    func `billing html maps five hour and weekly windows`() throws {
        let now = Date(timeIntervalSince1970: 1_782_222_000)
        let usage = try SakanaUsageFetcher.parseBillingHTML(
            Self.billingHTML,
            now: now,
            timeZone: Self.shanghaiTimeZone).toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 92)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == Self.date(year: 2026, month: 6, day: 23, hour: 22, minute: 53))
        #expect(usage.primary?.resetDescription == nil)
        #expect(usage.secondary?.usedPercent == 32)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.resetsAt == Self.date(year: 2026, month: 6, day: 29, hour: 8, minute: 0))
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
        let request = await transport.lastCapturedRequest()

        #expect(snapshot.fiveHour?.usedPercent == 92)
        #expect(request?.url == "https://console.sakana.ai/billing")
        #expect(request?.method == "GET")
        #expect(request?.cookie == "session=abc; theme=dark")
        #expect(request?.acceptLanguage == "en-US,en;q=0.9")
    }

    @Test
    func `fetch rejects cross origin login redirect`() async throws {
        let transport = try SakanaScriptedTransport(
            statusCode: 200,
            body: Self.billingHTML,
            responseURL: #require(URL(string: "https://auth.sakana.ai/login")))

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
            Self.billingHTML.replacing("June 23, 2026 at 10:53 PM", with: "soon-ish"),
            timeZone: Self.shanghaiTimeZone).toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 92)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.resetDescription == nil)
    }

    @Test
    func `window without reset line still maps percent`() throws {
        let html = Self.billingHTML.replacing(
            "<p class=\"text-muted-foreground text-xs tabular-nums\">Resets on June 23, 2026 at 10:53 PM</p>",
            with: "")
        let usage = try SakanaUsageFetcher.parseBillingHTML(
            html,
            timeZone: Self.shanghaiTimeZone).toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 92)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.resetDescription == nil)
        #expect(usage.secondary?.usedPercent == 32)
        #expect(usage.secondary?.resetsAt == Self.date(year: 2026, month: 6, day: 29, hour: 8, minute: 0))
    }

    @Test
    func `missing window percent rejects response without reading next quota window`() {
        let html = Self.billingHTML.replacing(
            "<p class=\"text-muted-foreground text-sm\">92% used</p>",
            with: "")

        #expect(throws: SakanaUsageError.parseFailed("Invalid 5-hour usage percentage.")) {
            _ = try SakanaUsageFetcher.parseBillingHTML(html, timeZone: Self.shanghaiTimeZone)
        }
    }

    private static let shanghaiTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    private static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.shanghaiTimeZone
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute))
    }

    private static let billingHTML = """
    <main>
      <div data-slot="card-title"><span>Standard</span><span>$20/mo</span></div>
      <div data-slot="card-title">Usage limit</div>
      <p class="font-medium text-sm">5-hour</p>
      <p class="text-muted-foreground text-xs tabular-nums">Resets on June 23, 2026 at 10:53 PM</p>
      <button aria-label="The 5-hour window starts with your first request."></button>
      <p class="text-muted-foreground text-sm">92% used</p>
      <p class="font-medium text-sm">Weekly</p>
      <p class="text-muted-foreground text-xs tabular-nums">Resets on June 29, 2026 at 8:00 AM</p>
      <button aria-label="Weekly usage resets every Monday at 00:00 UTC."></button>
      <p class="text-muted-foreground text-sm">32% used</p>
    </main>
    """
}

private actor SakanaScriptedTransport: ProviderHTTPTransport {
    struct CapturedRequest: Sendable {
        let url: String?
        let method: String?
        let cookie: String?
        let acceptLanguage: String?
    }

    private let statusCode: Int
    private let body: String
    private let responseURL: URL?
    private let headers: [String: String]
    private var capturedRequest: CapturedRequest?

    init(
        statusCode: Int,
        body: String,
        responseURL: URL? = nil,
        headers: [String: String] = [:])
    {
        self.statusCode = statusCode
        self.body = body
        self.responseURL = responseURL
        self.headers = headers
    }

    func lastCapturedRequest() -> CapturedRequest? {
        self.capturedRequest
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        self.capturedRequest = CapturedRequest(
            url: request.url?.absoluteString,
            method: request.httpMethod,
            cookie: request.value(forHTTPHeaderField: "Cookie"),
            acceptLanguage: request.value(forHTTPHeaderField: "Accept-Language"))
        let response = HTTPURLResponse(
            url: self.responseURL ?? request.url!,
            statusCode: self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: self.headers)!
        return (Data(self.body.utf8), response)
    }
}
