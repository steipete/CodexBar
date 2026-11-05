import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct AbacusPluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `credits billing calendar and formatting match native fixtures`(engine: ProviderPluginEngineKind) async throws {
        for (total, left) in [(1000.0, 750.0), (500, 500), (1000, -500), (0, 0), (100, 57.5), (2000, 999.5)] {
            for zone in ["UTC", "America/Los_Angeles"] {
                let reset = "2024-03-31T12:30:00Z"
                let runtime = try Self.runtime(engine, total: total, left: left, reset: reset)
                let now = Date(timeIntervalSince1970: 1_700_000_000)
                let timeZone = try #require(TimeZone(identifier: zone))
                let usage = try await runtime.fetchUsage(now: now, timeZone: timeZone, cookieResolver: Self.cookie)
                let primary = try #require(usage.primary)
                #expect(primary.usedPercent == (total > 0 ? min(100, max(0, (total - left) / total * 100)) : 0))
                #expect(primary.resetDescription == "\(Self.credits(total - left)) / \(Self.credits(total)) credits")
                let date = try #require(ISO8601DateParser.parse(reset))
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                let start = try #require(calendar.date(byAdding: .month, value: -1, to: date))
                #expect(primary.resetsAt == date)
                #expect(primary.windowMinutes == Int(date.timeIntervalSince(start) / 60))
                #expect(usage.identity?.providerID == .abacus)
                #expect(usage.identity?.loginMethod == "Pro")
                #expect(usage.identity?.accountEmail == nil)
                #expect(usage.secondary == nil)
                #expect(usage.updatedAt == now)
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["status", "auth", "json", "timeout", "date"])
    func `optional billing failures retain credits and fallback month`(
        engine: ProviderPluginEngineKind, failure: String) async throws
    {
        let runtime = try Self.runtime(engine, billingFailure: failure)
        let usage = try await runtime.fetchUsage(cookieResolver: Self.cookie)
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetDescription == "250 / 1,000 credits")
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.windowMinutes == 43200)
        #expect(usage.identity?.loginMethod == (failure == "date" ? "Pro" : nil))
    }

    @Test(.timeLimit(.minutes(1)), arguments: BundledPluginTestSupport.engines)
    func `five second billing deadline cancels pending billing and retains credits`(
        engine: ProviderPluginEngineKind) async throws
    {
        let (starts, started) = AsyncStream<Void>.makeStream()
        let (pending, release) = AsyncStream<Void>.makeStream()
        let (cancellations, cancelled) = AsyncStream<Bool>.makeStream()
        let (budgets, budgetObserved) = AsyncStream<Duration>.makeStream()
        defer {
            started.finish()
            release.finish()
            cancelled.finish()
            budgetObserved.finish()
        }
        let runtime = try BundledPluginTestSupport.runtime(
            "abacus",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.httpMethod == "GET")
                #expect(request.timeoutInterval == 15)
                return Self.response(request, body: Self.points)
            },
            contextOptions: ProviderPluginContextOptions(
                optionalRequestTimeoutSeconds: nil,
                waitForOptionalDeadline: { _, budget in
                    #expect(budget == .seconds(5))
                    // Expire collection only after billing is waiting before its independent request timer.
                    var iterator = starts.makeAsyncIterator()
                    #expect(await iterator.next() != nil)
                    budgetObserved.yield(budget)
                },
                beforeHTTPAttempt: { request in
                    guard request.httpMethod == "POST" else { return }
                    #expect(request.url?.path == "/api/_getBillingInfo")
                    #expect(request.timeoutInterval == 5)
                    started.yield()
                    for await _ in pending {}
                    cancelled.yield(Task.isCancelled)
                    cancelled.finish()
                    throw CancellationError()
                }))
        let usage = try await runtime.fetchUsage(cookieResolver: Self.cookie)
        budgetObserved.finish()
        var observedBudgets: [Duration] = []
        for await budget in budgets {
            observedBudgets.append(budget)
        }
        #expect(observedBudgets == [.seconds(5)])
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetDescription == "250 / 1,000 credits")
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.windowMinutes == 43200)
        #expect(usage.identity?.loginMethod == nil)
        var iterator = cancellations.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `failed imported sessions advance and reject only auth or parse failures`(
        engine: ProviderPluginEngineKind) async throws
    {
        for failure in ["auth", "json", "missing", "network"] {
            let sessions = Sessions()
            let runtime = try Self.runtime(engine, requiredFailure: failure)
            let usage = try await runtime.fetchUsage(
                cookieSessionResolver: { _, _ in sessions.next() },
                cookieSessionInvalidator: { _, id in sessions.reject(id) })
            #expect(usage.primary?.usedPercent == 25)
            #expect(sessions.rejected == (failure == "network" ? [] : ["stale"]))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `manual required errors propagate without trying another session`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try Self.runtime(engine, requiredFailure: "auth")
        let error = await #expect(throws: ProviderFetchClassifiedError.self) {
            try await runtime.fetchUsage(cookieSource: .manual, cookieResolver: { _, _ in "session=stale" })
        }
        #expect(error?.kind == .authenticationExpired)
        #expect(error?.localizedDescription.contains("Unauthorized") == true)
    }

    @Test(arguments: [2.0, 60.0, 90.0])
    func `descriptor preserves web timeout without the prototype switch`(timeout: Double) async throws {
        let strategy = AbacusProviderDescriptor.scriptStrategy(
            timeout: timeout,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.timeoutInterval == (request.httpMethod == "POST" ? min(timeout, 5) : timeout))
                return Self.response(request, body: request.httpMethod == "POST" ? Self.billing : Self.points)
            })
        let context = ProviderFetchContext(
            runtime: .cli, sourceMode: .web, includeCredits: false, webTimeout: timeout,
            webDebugDumpHTML: false, verbose: false, env: [:],
            settings: .make(abacus: .init(cookieSource: .manual, manualCookieHeader: "session=fixture")),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection()),
            browserDetection: BrowserDetection())
        #expect(await strategy.isAvailable(context))
        #expect(try await strategy.fetch(context).sourceLabel == "web")
    }

    @Test
    func `configured credits request can outlive the default plugin budget`() async throws {
        let strategy = AbacusProviderDescriptor.scriptStrategy(
            timeout: 60,
            transport: ProviderHTTPTransportHandler { request in
                if request.httpMethod == "GET" { try await Task.sleep(for: .seconds(21)) }
                return Self.response(request, body: request.httpMethod == "POST" ? Self.billing : Self.points)
            })
        let context = ProviderFetchContext(
            runtime: .cli, sourceMode: .web, includeCredits: false, webTimeout: 60,
            webDebugDumpHTML: false, verbose: false, env: [:],
            settings: .make(abacus: .init(cookieSource: .manual, manualCookieHeader: "session=fixture")),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection()),
            browserDetection: BrowserDetection())
        #expect(try await strategy.fetch(context).usage.primary?.usedPercent == 25)
    }

    @Test(.timeLimit(.minutes(1)), arguments: BundledPluginTestSupport.engines)
    func `slow first candidate leaves time for a successful second candidate`(
        engine: ProviderPluginEngineKind) async throws
    {
        let sessions = Sessions()
        let (cancellations, cancelled) = AsyncStream<Bool>.makeStream()
        defer { cancelled.finish() }
        // The successful candidate must not race an artificial sleep against its request deadline.
        let requestTimeout = 15.0
        let bundle = try #require(CodexBarCoreResources.bundle)
        let url = try #require(bundle.url(forResource: "abacus", withExtension: "js"))
        let runtime = try ProviderPluginRuntime(
            source: String(contentsOf: url, encoding: .utf8),
            resourceBundle: bundle,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.timeoutInterval == (request.httpMethod == "POST" ? 5 : requestTimeout))
                if request.httpMethod == "POST" { return Self.response(request, body: Self.billing) }
                if request.value(forHTTPHeaderField: "Cookie") == "session=stale" {
                    let (pending, release) = AsyncStream<Void>.makeStream()
                    defer { release.finish() }
                    for await _ in pending {}
                    cancelled.yield(Task.isCancelled)
                    try Task.checkCancellation()
                }
                return Self.response(request, body: Self.points)
            },
            timeout: AbacusProviderDescriptor.refreshTimeout(for: requestTimeout),
            engine: engine)
        let usage = try await runtime.fetchUsage(
            settings: ["REQUEST_TIMEOUT": String(requestTimeout)],
            cookieSessionResolver: { _, _ in sessions.next() },
            cookieSessionInvalidator: { _, id in sessions.reject(id) })
        #expect(usage.primary?.usedPercent == 25)
        #expect(sessions.rejected.isEmpty)
        var iterator = cancellations.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `candidate attempts are bounded even when the resolver keeps returning sessions`(
        engine: ProviderPluginEngineKind) async throws
    {
        let sessions = Sessions()
        let runtime = try Self.runtime(engine, requiredFailure: "auth")
        await #expect(throws: ProviderFetchClassifiedError.self) {
            try await runtime.fetchUsage(
                cookieSessionResolver: { _, _ in
                    .init(header: "session=stale", source: "Fixture", origin: "https://apps.abacus.ai", id: "stale")
                },
                cookieSessionInvalidator: { _, id in sessions.reject(id) })
        }
        #expect(sessions.rejected.count == AbacusProviderDescriptor.maximumCookieCandidates)
    }

    @Test(arguments: [1.0, 2.0, 15.0, 60.0, 90.0])
    func `refresh budget covers bounded candidates and never exceeds ninety seconds`(timeout: Double) {
        #expect(AbacusProviderDescriptor.refreshTimeout(for: timeout) == min(90, timeout * 5 + min(timeout, 5)))
    }

    private static let points = #"{"success":true,"result":{"totalComputePoints":1000,"computePointsLeft":750}}"#
    private static let billing = #"{"success":true,"result":{"currentTier":"Pro","nextBillingDate":"2024-03-31T12:30:00Z"}}"#
    private static let cookie: ProviderPluginRuntime.CookieResolver = { _, domain in
        #expect(domain == "apps.abacus.ai")
        return "session=fixture"
    }

    private static func runtime(
        _ engine: ProviderPluginEngineKind,
        total: Double = 1000,
        left: Double = 750,
        reset: String = "2024-03-31T12:30:00Z",
        billingFailure: String = "",
        requiredFailure: String = "") throws -> ProviderPluginRuntime
    {
        try BundledPluginTestSupport.runtime(
            "abacus",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.host == "apps.abacus.ai")
                #expect(request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("session=") == true)
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                if request.httpMethod == "POST" {
                    #expect(request.url?.path == "/api/_getBillingInfo")
                    #expect(request.httpBody == Data("{}".utf8))
                    #expect(request.timeoutInterval == 5)
                    switch billingFailure {
                    case "status": return Self.response(request, body: "unavailable", status: 500)
                    case "auth": return Self.response(request, body: #"{"success":false,"error":"session expired"}"#)
                    case "json": return Self.response(request, body: "<html>error</html>")
                    case "timeout": throw URLError(.timedOut)
                    default: break
                    }
                    let date = billingFailure == "date" ? "not-a-date" : reset
                    return Self.response(request, body: """
                    {"success":true,"result":{"currentTier":"Pro","nextBillingDate":"\(date)"}}
                    """)
                }
                #expect(request.url?.path == "/api/_getOrganizationComputePoints")
                #expect(request.httpMethod == "GET")
                #expect(request.timeoutInterval == 15)
                if request.value(forHTTPHeaderField: "Cookie") == "session=stale" {
                    switch requiredFailure {
                    case "auth": return Self.response(request, body: "", status: 401)
                    case "json": return Self.response(request, body: "[]")
                    case "missing": return Self.response(request, body: #"{"success":true,"result":{}}"#)
                    case "network": throw URLError(.cannotConnectToHost)
                    default: break
                    }
                }
                return Self.response(request, body: """
                {"success":true,"result":{"totalComputePoints":\(total),"computePointsLeft":\(left)}}
                """)
            })
    }

    private static func credits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 1
        return formatter.string(from: NSNumber(value: value))!
    }

    private static func response(_ request: URLRequest, body: String, status: Int = 200) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private final class Sessions: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var rejections: [String] = []
        var rejected: [String] {
            self.lock.withLock { self.rejections }
        }

        func reject(_ id: String) { self.lock.withLock { self.rejections.append(id) } }
        func next() -> ProviderPluginCookieSession? {
            self.lock.withLock {
                guard self.count < 2 else { return nil }
                let id = self.count == 0 ? "stale" : "fresh"
                self.count += 1
                return .init(header: "session=\(id)", source: "Fixture", origin: "https://apps.abacus.ai", id: id)
            }
        }
    }
}
