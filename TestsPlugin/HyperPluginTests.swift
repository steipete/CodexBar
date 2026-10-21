import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct HyperPluginTests {
    #if canImport(JavaScriptCore)
    private static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    private static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif

    private static let teamID = "11111111-2222-3333-4444-555555555555"
    private static let dashboardURL = "https://hyper.charm.land/teams/\(Self.teamID)/dashboard"
    private static let landingURL = "https://hyper.charm.land/"

    /// Mirrors the signed-in team dashboard markup: balance card, plan card, refresh note, API key count.
    private static let dashboardHTML = """
    <html><head><title>Dashboard — Charm™ Hyper</title></head><body>
    <div class="rounded-xl bg-card p-5">
      <p class="text-sm">Hypercredits Available</p>
      <div class="mt-1 flex items-center gap-1">
        <img src="/static/hexy.webp" alt="" width="34" height="34" />
        <p class="text-5xl font-bold">100</p>
      </div>
    </div>
    <div class="rounded-xl bg-card p-5">
      <p class="text-sm">Plan</p>
      <p class="text-3xl font-bold">Free</p>
      <a href="/teams/\(Self.teamID)/billing">Upgrade Plan</a>
      <p class="text-sm">Next Hypercredit refresh in 1 week</p>
    </div>
    <div class="rounded-xl bg-card p-5">
      <p class="text-sm">API Keys</p>
      <p class="mt-1 text-5xl font-bold">0</p>
    </div>
    </body></html>
    """

    /// Signed-out marketing page served for a session cookie that no longer authenticates.
    private static let landingHTML = """
    <html><head><title>Charm™ Hyper — Built for Coding Agents</title></head><body>
    <p>Hypercredits per month.</p>
    </body></html>
    """

    @Test(arguments: Self.engines)
    func `draft balance fixtures retain native HC without fabricated limits`(
        engine: ProviderPluginEngineKind) async throws
    {
        for balance in [0, 12, 18.5, 42.5] {
            let snapshot = try await Self.fetch(engine: engine, apiBody: "{\"balance\":\(balance)}")
            #expect(snapshot.providerCost == nil)
            #expect(snapshot.details.first?.rows.first?.usageValue == balance)
            #expect(snapshot.primary == nil)
            #expect(snapshot.secondary == nil)
            #expect(snapshot.identity?.providerID == .hyper)
            #expect(snapshot.identity?.loginMethod == "API key")
            #expect(snapshot.dataConfidence == .exact)
            #expect(snapshot.details.first?.rows.first?.value.hasSuffix(" HC") == true)
        }
    }

    @Test(arguments: Self.engines)
    func `session dashboard wins over key without a credits request`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(
            engine: engine, cookie: "JSESSIONID=fixture-session",
            expectedRequests: ["https://hyper.charm.land/"])
        #expect(snapshot.details.first?.rows.first?.usageValue == 100)
        #expect(snapshot.details.first?.rows.first?.value == "100 HC")
        #expect(snapshot.identity?.loginMethod == "Browser session")
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.primary == nil)
        let labels = (snapshot.details.first?.rows ?? []).map(\.label)
        #expect(labels == ["Balance"])
    }

    @Test(arguments: Self.engines)
    func `automatic browser session works without an API key`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(
            engine: engine, key: "", cookie: "JSESSIONID=fixture-session", cookieSource: .auto,
            expectedRequests: [Self.landingURL])
        #expect(snapshot.details.first?.rows.first?.usageValue == 100)
        #expect(snapshot.identity?.loginMethod == "Browser session")
    }

    @Test(arguments: Self.engines)
    func `API source bypasses cookie resolver`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine, cookie: "session=unused", mode: .api)
        #expect(snapshot.identity?.loginMethod == "API key")
    }

    @Test(arguments: Self.engines)
    func `missing session falls back to key`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine, cookie: "")
        #expect(snapshot.identity?.loginMethod == "API key")
    }

    @Test(arguments: [
        (401, Self.dashboardHTML, Self.dashboardURL),
        (403, Self.dashboardHTML, Self.dashboardURL),
        (302, Self.landingHTML, Self.landingURL),
        (200, Self.landingHTML, Self.landingURL),
    ], Self.engines)
    func `expired session is rejected before API fallback`(
        fixture: (Int, String, String),
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(
            engine: engine, cookie: "session=fixture-rejected-session",
            sessionStatus: fixture.0, sessionBody: fixture.1, sessionURL: fixture.2)
        #expect(snapshot.identity?.loginMethod == "API key")
    }

    @Test(arguments: [
        (401, Self.dashboardHTML, Self.dashboardURL),
        (403, Self.dashboardHTML, Self.dashboardURL),
        (302, Self.landingHTML, Self.landingURL),
        (200, Self.landingHTML, Self.landingURL),
    ], Self.engines)
    func `web only never falls back to configured key`(
        fixture: (Int, String, String),
        engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, cookie: "session=fixture-rejected-session", mode: .web,
                sessionStatus: fixture.0, sessionBody: fixture.1, sessionURL: fixture.2)
            Issue.record("Expected expired session")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [
        (ProviderCookieSource.manual, "Paste a fresh Cookie header in Settings"),
        (ProviderCookieSource.auto, "Sign in again at hyper.charm.land"),
    ], Self.engines)
    func `expired session guidance matches the cookie source`(
        expected: (ProviderCookieSource, String),
        engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, key: "", cookie: "session=fixture-expired", cookieSource: expected.0,
                sessionStatus: 200, sessionBody: Self.landingHTML, sessionURL: Self.landingURL)
            Issue.record("Expected expired session")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
            #expect(error.message.contains(expected.1))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: Self.engines)
    func `dashboard without a balance card fails closed instead of guessing`(engine: ProviderPluginEngineKind) async {
        let body = """
        <html><body><a href="/teams/\(Self.teamID)/dashboard">Dashboard</a>
        <p class="text-sm">Hypercredits Available</p></body></html>
        """
        do {
            _ = try await Self.fetch(
                engine: engine, cookie: "session=fixture", sessionBody: body, sessionURL: Self.dashboardURL)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: Self.engines)
    func `dashboard balance rejects a numeric prefix of malformed text`(engine: ProviderPluginEngineKind) async {
        do {
            _ = try await Self.fetch(
                engine: engine, cookie: "session=fixture", mode: .web,
                sessionBody: Self.dashboardHTML.replacingOccurrences(of: ">100<", with: ">100oops<"))
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [
        "",
        "{}",
        #"{"balance":"#,
        #"{"balance":-1}"#,
        #"{"balance":"invalid"}"#,
        #"{"balance":null}"#,
        #"{"balance":true}"#,
        #"{"balance":1e400}"#,
        "null",
        "[]"
    ], Self.engines)
    func `malformed API balances fail closed`(
        body: String, engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, apiBody: body)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .permissionDenied),
        (429, .rateLimited),
        (503, .providerUnavailable),
        (404, .apiFailure)
    ], Self.engines)
    func `HTTP errors are classified without exposing response or key`(
        fixture: (Int, ProviderFetchClassifiedError.Kind), engine: ProviderPluginEngineKind) async
    {
        do {
            _ = try await Self.fetch(
                engine: engine, apiBody: "private upstream body fixture-key", apiStatus: fixture.0)
            Issue.record("Expected HTTP failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == fixture.1)
            #expect(!error.message.contains("private upstream body"))
            #expect(!error.message.contains("fixture-key"))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(arguments: Self.engines)
    func `no credentials produce guidance without HTTP`(engine: ProviderPluginEngineKind) async {
        do {
            _ = try await Self.fetch(engine: engine, key: "", expectedRequests: [])
            Issue.record("Expected missing credential")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .missingCredential)
            #expect(error.message.contains("Sign in"))
            #expect(error.message.contains("API key"))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test
    func `registry projects config and keeps balance provider opt in`() throws {
        let descriptor = HyperProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        let environment = credentials.applyConfig(
            base: ["HYPER_API_KEY": "old-key", "OTHER": "preserved"],
            config: ProviderConfig(id: .hyper, apiKey: " 'fixture-key' "))
        #expect(credentials.resolveToken(environment: environment)?.token == "fixture-key")
        #expect(environment["OTHER"] == "preserved")
        #expect(HyperProviderDescriptor.apiKey(environment: ["HYPER_API_KEY": "  "]) == nil)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web, .api])
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(!descriptor.metadata.widgetSelectable)
        #expect(descriptor.metadata.balanceOnly)
        if case let .environment(key) = credentials.tokenAccountSupport?.injection {
            #expect(key == "HYPER_API_KEY")
        } else {
            Issue.record("Expected API-key token accounts")
        }
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        apiBody: String = #"{"balance":42.5}"#,
        key: String = "fixture-key",
        cookie: String? = nil,
        cookieSource: ProviderCookieSource? = nil,
        mode: ProviderSourceMode = .auto,
        sessionStatus: Int = 200,
        sessionBody: String = Self.dashboardHTML,
        sessionURL: String = Self.dashboardURL,
        apiStatus: Int = 200,
        expectedRequests: [String]? = nil) async throws -> UsageSnapshot
    {
        let rejected = HyperRejectionRecorder()
        let requests = HyperRequestRecorder()
        let source = cookieSource ?? (cookie == nil ? .off : .manual)
        let expectsSession = cookie?.isEmpty == false && mode != .api && source != .off
        let sessionSucceeded = expectsSession && sessionStatus == 200 && sessionBody.contains("/teams/\(Self.teamID)")
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            requests.record(url.absoluteString)
            if url.absoluteString == "https://hyper.charm.land/" {
                #expect(expectsSession)
                #expect(request.value(forHTTPHeaderField: "Cookie") == cookie)
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.value(forHTTPHeaderField: "Accept") == "text/html")
                let response = try #require(HTTPURLResponse(
                    url: URL(string: sessionURL) ?? url, statusCode: sessionStatus, httpVersion: nil,
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]))
                return (Data(sessionBody.utf8), response)
            }
            #expect(url.absoluteString == "https://hyper.charm.land/v1/credits")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
            #expect(mode != .web)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: apiStatus, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(apiBody.utf8), response)
        }
        let url = try #require(CodexBarCoreResources.bundle?.url(forResource: "hyper", withExtension: "js"))
        let runtime = try ProviderPluginRuntime(
            source: String(contentsOf: url, encoding: .utf8), transport: transport, engine: engine)
        let result = try await runtime.fetchResult(
            settings: ["SOURCE_MODE": mode.rawValue], secrets: ["HYPER_API_KEY": key],
            sourceMode: mode, cookieSource: source,
            cookieInvalidator: { domain in
                #expect(domain == "hyper.charm.land")
                rejected.record()
            },
            cookieResolver: { provider, domain in
                #expect(mode != .api)
                #expect(provider == .hyper)
                #expect(domain == "hyper.charm.land")
                guard let cookie, !cookie.isEmpty else { throw ProviderPluginError.secretAccess("fixture missing") }
                return cookie
            })
        #expect(result.sourceLabel == (sessionSucceeded ? "web" : "api"))
        #expect(rejected.count == (expectsSession && !sessionSucceeded ? 1 : 0))
        if let expectedRequests {
            #expect(requests.urls == expectedRequests)
        }
        return result.usage
    }
}

private final class HyperRejectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        self.lock.withLock { self.value }
    }

    func record() { self.lock.withLock { self.value += 1 } }
}

private final class HyperRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    var urls: [String] {
        self.lock.withLock { self.value }
    }

    func record(_ url: String) { self.lock.withLock { self.value.append(url) } }
}
