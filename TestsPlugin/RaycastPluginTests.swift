import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

/// Plugin-engine coverage for the bundled Raycast credits script.
struct RaycastPluginTests {
    static let credits = #"""
    {
      "remaining_balance_credits": "125",
      "total_balance_credits": "500",
      "next_credits_at": "2026-10-18T00:00:00.000Z",
      "can_top_up": true,
      "can_upgrade_plan": true,
      "funding_subscription": {
        "tier": "pro",
        "source": "personal",
        "provider": "stripe",
        "status": "active",
        "canceled": false
      }
    }
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `monthly credits become one meter with the remaining balance`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(Self.credits, engine: engine)
        #expect(snapshot.primary?.usedPercent == 75)
        #expect(snapshot.primary?.windowMinutes == nil)
        #expect(snapshot.primary?.resetsAt == Self.date("2026-10-18T00:00:00.000Z"))
        #expect(snapshot.primary?.resetDescription == "125 / 500 credits left")
        #expect(snapshot.subscriptionRenewsAt == nil)
        #expect(snapshot.identity?.providerID == .raycast)
        #expect(snapshot.identity?.loginMethod == "Pro")
        #expect(snapshot.details.isEmpty)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `website account payload maps left and total`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"""
        {
          "remaining_balance_credits": "337.3751",
          "total_balance_credits": "500.0",
          "next_credits_at": "2026-10-18T08:34:44Z",
          "funding_subscription": {"tier": "pro", "status": "active"}
        }
        """#, engine: engine)
        #expect(abs((snapshot.primary?.usedPercent ?? 0) - 32.525) < 0.01)
        #expect(snapshot.primary?.resetDescription == "337.38 / 500 credits left")
        #expect(snapshot.details.isEmpty)
        #expect(snapshot.identity?.loginMethod == "Pro")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `numeric amounts and Pro Plus labels are preserved`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"""
        {
          "remaining_balance_credits": 12.5,
          "total_balance_credits": 50,
          "funding_subscription": {"tier": "pro_plus"}
        }
        """#, engine: engine)
        #expect(snapshot.primary?.usedPercent == 75)
        #expect(snapshot.primary?.resetDescription == "12.5 / 50 credits left")
        #expect(snapshot.details.isEmpty)
        #expect(snapshot.identity?.loginMethod == "Pro+")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rollover remaining above the current grant does not invent extra usage`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(#"""
        {"remaining_balance_credits":"750","total_balance_credits":"500"}
        """#, engine: engine)
        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.primary?.resetDescription == "750 / 500 credits left")
        #expect(snapshot.details.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `zero allowance does not invent a quota window`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"""
        {"remaining_balance_credits":"0","total_balance_credits":"0","next_credits_at":"2026-10-18T00:00:00.000Z","funding_subscription":{"tier":"max"}}
        """#, engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.subscriptionRenewsAt == Self.date("2026-10-18T00:00:00.000Z"))
        #expect(snapshot.identity?.loginMethod == "Max")
        #expect(snapshot.details[0].rows.map(\.label) == ["Left", "Total"])
        #expect(snapshot.details[0].rows.map(\.value) == ["0", "0"])
    }

    @Test(
        arguments: ["true", "false", "\"NaN\"", "\"Infinity\"", "\"\"", "[]", "{}", "1e400"],
        BundledPluginTestSupport.engines)
    func `invalid amounts fail instead of publishing exact zero`(
        value: String,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.parseFailure) {
            _ = try await Self.fetch("{\"remaining_balance_credits\":\(value)}", engine: engine)
        }
    }

    @Test(arguments: ["null", "[]", "{}", "{\"funding_subscription\":{}}"], BundledPluginTestSupport.engines)
    func `empty credit responses stay unavailable`(body: String, engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.parseFailure) {
            _ = try await Self.fetch(body, engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `requests use the website session cookie headers and timeout`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "raycast",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(
                    request.url?.absoluteString
                        == "https://www.raycast.com/frontend_api/current_user/ai_credits")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.value(forHTTPHeaderField: "Cookie") == Self.fixtureCookie)
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.raycast.com")
                #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.raycast.com/settings")
                #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/") == true)
                #expect(request.timeoutInterval == 22)
                return try Self.response(request, body: Self.credits)
            })
        _ = try await runtime.fetchUsage(
            settings: ["webTimeoutSeconds": "22"],
            cookieResolver: Self.cookieResolver)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `empty browser import is a missing credential not a script crash`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "raycast",
            engine: engine,
            transport: ProviderHTTPTransportHandler { _ in
                Issue.record("Must not fetch without a session cookie")
                throw ProviderPluginError.secretAccess("unreachable")
            })
        do {
            _ = try await runtime.fetchUsage(cookieSessionResolver: { _, _ in nil })
            Issue.record("Expected missing credential")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .missingCredential)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing session cookie stays unavailable`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "raycast",
            engine: engine,
            transport: ProviderHTTPTransportHandler { _ in
                Issue.record("Must not fetch without __raycast_session")
                throw ProviderPluginError.secretAccess("unreachable")
            })
        do {
            _ = try await runtime.fetchUsage(cookieResolver: { _, _ in "csrf_token=only" })
            Issue.record("Expected missing session cookie")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .missingCredential)
            #expect(error
                .message ==
                "No Raycast session cookies found. Sign in at www.raycast.com/settings or paste a Cookie header.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `empty session cookie value stays unavailable`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "raycast",
            engine: engine,
            transport: ProviderHTTPTransportHandler { _ in
                Issue.record("Must not fetch with an empty __raycast_session")
                throw ProviderPluginError.secretAccess("unreachable")
            })
        do {
            _ = try await runtime.fetchUsage(cookieResolver: { _, _ in
                "__raycast_session=; csrf_token=fixture-csrf"
            })
            Issue.record("Expected missing session cookie")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .missingCredential)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .permissionDenied),
        (429, .rateLimited),
        (503, .providerUnavailable),
    ], BundledPluginTestSupport.engines)
    func `credit failures retain actionable classification`(
        failure: (Int, ProviderFetchClassifiedError.Kind),
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(failure.1) {
            _ = try await Self.fetch("{}", engine: engine, status: failure.0)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rejected candidates advance within the same refresh`(engine: ProviderPluginEngineKind) async throws {
        let sessions = SessionTrace(headers: ["csrf_token=only", "__raycast_session=rejected-fixture-session", Self.fixtureCookie])
        let runtime = try BundledPluginTestSupport.runtime(
            "raycast", engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let header = request.value(forHTTPHeaderField: "Cookie") ?? ""
                sessions.request(header)
                return try Self.response(request, body: Self.credits, status: header.contains("rejected-fixture-session") ? 401 : 200)
            })
        let usage = try await runtime.fetchUsage(
            cookieSessionResolver: { domain, _ in
                #expect(domain == "www.raycast.com")
                return sessions.next()
            },
            cookieSessionInvalidator: { domain, id in
                #expect(domain == "www.raycast.com")
                sessions.reject(id)
            })
        #expect(usage.primary?.usedPercent == 75)
        #expect(sessions.requested == ["__raycast_session=rejected-fixture-session", Self.fixtureCookie])
        #expect(sessions.rejected == Array(sessions.candidates.prefix(2).map(\.id)))
    }

    @Test(arguments: [ProviderCookieSource.manual, .off], BundledPluginTestSupport.engines)
    func `manual and off never advance to another account`(
        source: ProviderCookieSource, engine: ProviderPluginEngineKind) async throws
    {
        let sessions = SessionTrace(headers: ["__raycast_session=rejected-fixture-session", Self.fixtureCookie])
        let runtime = try BundledPluginTestSupport.runtime(
            "raycast", engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                sessions.request(request.value(forHTTPHeaderField: "Cookie") ?? "")
                return try Self.response(request, body: "{}", status: 401)
            })
        await Self.expectFailure(source == .off ? .missingCredential : .authenticationExpired) {
            _ = try await runtime.fetchUsage(
                cookieSource: source,
                cookieSessionResolver: { _, _ in sessions.next() },
                cookieSessionInvalidator: { _, id in sessions.reject(id) })
        }
        #expect(sessions.consumed == (source == .off ? 0 : 1))
        #expect(sessions.requested.count == (source == .off ? 0 : 1))
    }

    @Test(arguments: [403, 429, 503, 200], BundledPluginTestSupport.engines)
    func `non authentication errors preserve the candidate and stop retries`(
        status: Int, engine: ProviderPluginEngineKind) async throws
    {
        let sessions = SessionTrace(headers: [Self.fixtureCookie, "__raycast_session=other"])
        let runtime = try BundledPluginTestSupport.runtime(
            "raycast", engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                sessions.request(request.value(forHTTPHeaderField: "Cookie") ?? "")
                return try Self.response(request, body: "invalid JSON", status: status)
            })
        let expected: ProviderFetchClassifiedError.Kind = switch status {
        case 403: .permissionDenied
        case 429: .rateLimited
        case 503: .providerUnavailable
        default: .parseFailure
        }
        await Self.expectFailure(expected) {
            _ = try await runtime.fetchUsage(
                cookieSessionResolver: { _, _ in sessions.next() },
                cookieSessionInvalidator: { _, id in sessions.reject(id) })
        }
        #expect(sessions.consumed == 1)
        #expect(sessions.requested.count == 1)
        #expect(sessions.rejected.isEmpty)
    }

    private final class SessionTrace: @unchecked Sendable {
        let candidates: [ProviderPluginCookieSession]
        private let lock = NSLock()
        private var index = 0
        private var requests: [String] = []
        private var rejections: [String] = []

        init(headers: [String]) {
            self.candidates = headers.map {
                ProviderPluginCookieSession(header: $0, source: "Fixture", origin: "https://www.raycast.com")
            }
        }

        func next() -> ProviderPluginCookieSession? {
            self.lock.withLock {
                guard self.index < self.candidates.count else { return nil }
                defer { self.index += 1 }
                return self.candidates[self.index]
            }
        }

        func request(_ header: String) { self.lock.withLock { self.requests.append(header) } }
        func reject(_ id: String) { self.lock.withLock { self.rejections.append(id) } }
        var consumed: Int {
            self.lock.withLock { self.index }
        }

        var requested: [String] {
            self.lock.withLock { self.requests }
        }

        var rejected: [String] {
            self.lock.withLock { self.rejections }
        }
    }

    static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind,
        status: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "raycast",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request, body: body, status: status)
            })
        return try await runtime.fetchUsage(cookieResolver: Self.cookieResolver)
    }

    private static let fixtureCookie = "__raycast_session=fixture-session; csrf_token=fixture-csrf"

    private static let cookieResolver: ProviderPluginRuntime.CookieResolver = { provider, domain in
        #expect(provider == .raycast)
        #expect(domain == "www.raycast.com")
        return Self.fixtureCookie
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        perform: () async throws -> Void) async
    {
        do {
            try await perform()
            Issue.record("Expected classified failure \(kind)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func date(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200) throws -> (Data, URLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
}
