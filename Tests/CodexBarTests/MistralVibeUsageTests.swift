import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

private final class MistralRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        self.lock.withLock { self.storedRequest }
    }

    func record(_ request: URLRequest) {
        self.lock.withLock { self.storedRequest = request }
    }
}

private final class MistralRequestPathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPaths: [String] = []

    var paths: [String] {
        self.lock.withLock { self.storedPaths }
    }

    func record(_ request: URLRequest) {
        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        self.lock.withLock {
            self.storedPaths.append("\(host)\(path)")
        }
    }
}

struct MistralVibeUsageTests {
    #if os(macOS)
    @Test
    func `cookie importer uses only accepted Mistral domains`() {
        #expect(Set(MistralCookieImporter.cookieDomains) == [
            "mistral.ai",
            "admin.mistral.ai",
            "auth.mistral.ai",
            "console.mistral.ai",
        ])
    }
    #endif

    @Test
    func `parses subscription percentage and reset`() throws {
        let data = Data(Self.responseJSON(usagePercentage: 2.8141356666666666).utf8)

        let result = try MistralUsageFetcher.parseVibeUsage(data: data)

        #expect(result.usagePercentage == 2.8141356666666666)
        #expect(result.resetAt == ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
    }

    @Test
    func `rejects subscription percentages outside rate window range`() {
        let data = Data(Self.responseJSON(usagePercentage: 101).utf8)

        #expect(throws: MistralUsageError.self) {
            try MistralUsageFetcher.parseVibeUsage(data: data)
        }
    }

    @Test
    func `subscription request sends only csrf cookie`() async throws {
        let capture = MistralRequestCapture()
        let data = Data(Self.responseJSON(usagePercentage: 12.5).utf8)
        let transport = ProviderHTTPTransportHandler { request in
            capture.record(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: nil)
            else {
                throw URLError(.badURL)
            }
            return (data, response)
        }

        let result = try await MistralUsageFetcher.fetchVibeUsage(
            csrfToken: " csrf-value ",
            timeout: 2,
            transport: transport)
        let request = try #require(capture.request)

        #expect(result.usagePercentage == 12.5)
        #expect(request.url?.host == "console.mistral.ai")
        #expect(request.timeoutInterval == 2)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "csrftoken=csrf-value")
        #expect(request.value(forHTTPHeaderField: "X-CSRFToken") == "csrf-value")
        #expect(request.allHTTPHeaderFields?.values.contains { $0.contains("ory_session") } != true)
    }

    @Test
    func `rejects csrf values that could add cookies or headers`() {
        #expect(throws: MistralUsageError.self) {
            try MistralUsageFetcher.vibeCookieHeader(csrfToken: "csrf; ory_session_secret=leak")
        }
        #expect(throws: MistralUsageError.self) {
            try MistralUsageFetcher.vibeCookieHeader(csrfToken: "csrf\r\nX-Leak: value")
        }
    }

    @Test
    func `optional subscription request propagates in flight cancellation`() async throws {
        let started = AsyncStream<Void>.makeStream(of: Void.self)
        let transport = ProviderHTTPTransportHandler { _ in
            started.continuation.yield(())
            try await Task.sleep(for: .seconds(30))
            throw URLError(.timedOut)
        }
        let task = Task {
            try await MistralWebFetchStrategy.fetchOptionalVibeUsage(
                csrfToken: "csrf-value",
                timeout: 30,
                transport: transport)
        }

        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        started.continuation.finish()
    }

    @Test
    func `optional subscription request ignores ordinary endpoint failures`() async throws {
        let transport = ProviderHTTPTransportHandler { _ in
            throw URLError(.cannotConnectToHost)
        }

        let result = try await MistralWebFetchStrategy.fetchOptionalVibeUsage(
            csrfToken: "csrf-value",
            timeout: 2,
            transport: transport)

        #expect(result == nil)
    }

    @Test
    func `combined fetch preserves monthly plan when optional credits time out`() async throws {
        let requestLog = MistralRequestPathLog()
        let usageData = Data(Self.billingUsageResponseJSON.utf8)
        let vibeData = Data(Self.responseJSON(usagePercentage: 37).utf8)
        let transport = ProviderHTTPTransportHandler { request in
            requestLog.record(request)
            guard let url = request.url else { throw URLError(.badURL) }
            if url.host == "admin.mistral.ai", url.path == "/api/billing/v2/usage" {
                let response = try Self.response(url: url, statusCode: 200)
                return (usageData, response)
            }
            if url.host == "console.mistral.ai" {
                let response = try Self.response(url: url, statusCode: 200)
                return (vibeData, response)
            }
            if url.host == "admin.mistral.ai", url.path == "/api/billing/credits" {
                try await Task.sleep(for: .milliseconds(25))
                throw URLError(.timedOut)
            }
            throw URLError(.badURL)
        }

        let snapshot = try await MistralWebFetchStrategy.fetchUsageWithVibe(
            cookieHeader: "ory_session_test=abc; csrftoken=csrf",
            csrfToken: "csrf",
            timeout: 1,
            transport: transport)

        let monthlyPlan = snapshot.extraRateWindows?.first { $0.id == "mistral-monthly-plan" }
        #expect(monthlyPlan?.window.usedPercent == 37)
        #expect(snapshot.mistralUsage?.credits == nil)
        #expect(requestLog.paths == [
            "admin.mistral.ai/api/billing/v2/usage",
            "console.mistral.ai/api-ui/trpc/billing.vibeUsage",
            "admin.mistral.ai/api/billing/credits",
        ])
    }

    @Test
    func `monthly plan window preserves existing extras`() {
        let existing = NamedRateWindow(
            id: "existing",
            title: "Existing",
            window: RateWindow(usedPercent: 5, windowMinutes: nil, resetsAt: nil, resetDescription: nil))
        let usage = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [existing],
            updatedAt: Date())

        let updated = MistralWebFetchStrategy.attachVibeWindow(
            to: usage,
            vibeResult: .init(usagePercentage: 25, resetAt: nil))

        #expect(updated.extraRateWindows?.map(\.id) == ["existing", "mistral-monthly-plan"])
        #expect(updated.extraRateWindows?.last?.window.usedPercent == 25)
    }

    // MARK: - consoleCookieHeader allowlist

    @Test
    func `console cookie header contains only csrf when no admin header`() {
        let cookie = MistralUsageFetcher.consoleCookieHeader(csrfToken: "tok", adminCookieHeader: nil)
        #expect(cookie == "csrftoken=tok")
    }

    @Test
    func `console cookie header forwards ory session alongside csrf`() {
        let admin = "csrftoken=tok; ory_session_coolcurranf83m3srkfl=sess123; other_admin=secret"
        let cookie = MistralUsageFetcher.consoleCookieHeader(csrfToken: "tok", adminCookieHeader: admin)
        #expect(cookie == "csrftoken=tok; ory_session_coolcurranf83m3srkfl=sess123")
    }

    @Test
    func `console cookie header excludes non-session admin cookies`() {
        let admin = "csrftoken=tok; session_token=other; admin_secret=x"
        let cookie = MistralUsageFetcher.consoleCookieHeader(csrfToken: "tok", adminCookieHeader: admin)
        #expect(cookie == "csrftoken=tok")
        #expect(!cookie.contains("admin_secret"))
        #expect(!cookie.contains("session_token"))
    }

    @Test
    func `console cookie header forwards multiple ory session cookies`() {
        let admin = "ory_session_a=val1; ory_session_b=val2; unrelated=drop"
        let cookie = MistralUsageFetcher.consoleCookieHeader(csrfToken: "tok", adminCookieHeader: admin)
        #expect(cookie.contains("csrftoken=tok"))
        #expect(cookie.contains("ory_session_a=val1"))
        #expect(cookie.contains("ory_session_b=val2"))
        #expect(!cookie.contains("unrelated"))
    }

    private static func responseJSON(usagePercentage: Double) -> String {
        """
        [{"result":{"data":{"json":{
          "usage_percentage":\(usagePercentage),
          "quota_changed_this_month":false,
          "payg_enabled":false,
          "reset_at":"2026-07-01T00:00:00Z"
        }}}}]
        """
    }

    private static var billingUsageResponseJSON: String {
        """
        {
          "completion": {"models": {}},
          "ocr": {"models": {}},
          "connectors": {"models": {}},
          "libraries_api": {"pages": {"models": {}}, "tokens": {"models": {}}},
          "fine_tuning": {"training": {}, "storage": {}},
          "audio": {"models": {}},
          "vibe_usage": 0.0,
          "date": "2026-02-01T00:00:00Z",
          "previous_month": "2026-01",
          "next_month": "2026-03",
          "start_date": "2026-02-01T00:00:00Z",
          "end_date": "2026-02-28T23:59:59.999Z",
          "currency": "USD",
          "currency_symbol": "$",
          "prices": []
        }
        """
    }

    private static func response(url: URL, statusCode: Int) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil))
    }
}
