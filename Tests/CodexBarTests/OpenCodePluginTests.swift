import Foundation
import Testing
@testable import CodexBarCore

/// CookieHeaderCache, the refresh-suppression gate, and the Keychain service override are
/// process-global, so this suite must run serially like CookieHeaderCacheTests.
@Suite(.serialized)
struct OpenCodePluginTests {
    static let now = Date(timeIntervalSince1970: 1_789_000_000)

    private static let workspacesBody = #"{"workspaces":[{"id":"wrk_123abc"}]}"#
    private static let subscriptionBody = """
    {"rollingUsage":{"usagePercent":42.5,"resetInSec":3600},
     "weeklyUsage":{"usagePercent":65,"resetInSec":86400},
     "renewAt":"2026-10-01T00:00:00Z"}
    """
    private static let subscriptionSolidBody =
        #"self.$R=self.$R||[];u={rollingUsage:{usagePercent:12.5,resetInSec:1200},"# +
        #"weeklyUsage:{usagePercent:88,resetInSec:60000}}"#
    private static let billingSolidBody =
        #"customerID:$R[0]="cus_123",monthlyUsage:$R[1]=2500000000,"# +
        #"balance:$R[2]=100000000,monthlyLimit:$R[3]=50,subscription:$R[4]=null"#
    private static let billingNoLimitBody =
        #"{"customerID":"cus_x","monthlyUsage":500000000,"balance":200000000,"subscription":null}"#
    private static let billingSubscribedBody =
        #"{"customerID":"cus_x","monthlyUsage":500000000,"subscription":{"id":"sub_1"}}"#
    private static let serverErrorBody = "server error"

    @Test(arguments: BundledPluginTestSupport.engines)
    func `golden subscription renders rolling weekly and renewal`(
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(engine: engine)
        let usage = result.usage
        #expect(usage.primary?.usedPercent == 42.5)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == Self.now.addingTimeInterval(3600))
        #expect(usage.secondary?.usedPercent == 65)
        #expect(usage.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(usage.secondary?.resetsAt == Self.now.addingTimeInterval(86400))
        let renewal = try #require(usage.extraRateWindows?.first)
        #expect(renewal.id == "renewal")
        #expect(renewal.title == "Renews")
        #expect(renewal.window.usedPercent == 0)
        #expect(renewal.window.resetsAt == ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        #expect(result.requests.count == 2)
        #expect(result.requests.allSatisfy { $0.url?.host == "opencode.ai" })
        #expect(result.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "auth=session" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `SolidStart subscription payload parses through the regex fallback`(
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(engine: engine, subscription: Self.subscriptionSolidBody)
        #expect(result.usage.primary?.usedPercent == 12.5)
        #expect(result.usage.primary?.resetsAt == Self.now.addingTimeInterval(1200))
        #expect(result.usage.secondary?.usedPercent == 88)
        #expect(result.usage.secondary?.resetsAt == Self.now.addingTimeInterval(60000))
        #expect(result.usage.extraRateWindows == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `workspace resolution retries with POST when GET returns no ids`(
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(engine: engine, workspacesGet: #"{}"#)
        #expect(result.requests.count == 3)
        let post = result.requests[1]
        #expect(post.httpMethod == "POST")
        #expect(post.url?.absoluteString == "https://opencode.ai/_server")
        #expect(post.value(forHTTPHeaderField: "X-Server-Id")
            == "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f")
        let postBody = try JSONSerialization.jsonObject(with: #require(post.httpBody))
        #expect((postBody as? [String]) == [])
        let subscription = result.requests[2]
        #expect(subscription.url?.query?.contains("args=%5B%22wrk_123abc%22%5D") == true)
        #expect(subscription.value(forHTTPHeaderField: "Referer")
            == "https://opencode.ai/workspace/wrk_123abc/billing")
    }

    @Test(
        arguments: ["wrk_override", "https://opencode.ai/workspace/wrk_override"],
        BundledPluginTestSupport.engines)
    func `workspace id override skips the workspace lookup`(
        rawOverride: String,
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(
            engine: engine,
            settings: ["WORKSPACE_ID": rawOverride])
        #expect(result.requests.count == 1)
        #expect(result.requests[0].value(forHTTPHeaderField: "X-Server-Id")
            == "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4")
        #expect(result.requests[0].url?.query?.contains("args=%5B%22wrk_override%22%5D") == true)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `pay as you go falls back to billing when the subscription payload is null`(
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(
            engine: engine,
            subscription: #"x["server-fn:aaa"]=[],null)"#,
            billing: Self.billingSolidBody)
        #expect(result.requests.count == 3)
        #expect(result.requests[2].value(forHTTPHeaderField: "X-Server-Id")
            == "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d")
        #expect(result.usage.primary?.usedPercent == 50)
        #expect(result.usage.primary?.windowMinutes == 30 * 24 * 60)
        #expect(result.usage.primary?.resetsAt == nil)
        #expect(result.usage.providerCost?.used == 25)
        #expect(result.usage.providerCost?.limit == 50)
        #expect(result.usage.providerCost?.currencyCode == "USD")
        #expect(result.usage.providerCost?.period == "Monthly")
        #expect(result.usage.providerCost?.balance == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `pay as you go without a limit reports spend and balance only`(
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(
            engine: engine,
            subscription: "null",
            billing: Self.billingNoLimitBody)
        #expect(result.usage.primary == nil)
        #expect(result.usage.providerCost?.used == 5)
        #expect(result.usage.providerCost?.limit == 0)
        #expect(result.usage.providerCost?.balance == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billing payload that still reports a subscription preserves the subscription error`(
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.apiFailure) {
            try await Self.fetch(
                engine: engine,
                subscriptionStatus: 500,
                billing: Self.billingSubscribedBody).usage
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rejected session is evicted and the next profile succeeds`(
        engine: ProviderPluginEngineKind) async throws
    {
        let rejected = LockIsolated<[String]>([])
        let result = try await Self.fetch(
            engine: engine,
            sessions: ["opencode.ai": ["auth=stale", "auth=live"]],
            workspacesStatusByCookie: { cookie in cookie.contains("stale") ? 401 : 200 },
            rejected: rejected)
        #expect(result.usage.primary != nil)
        #expect(rejected.value == ["opencode.ai"])
        #expect(result.requests.first?.value(forHTTPHeaderField: "Cookie") == "auth=stale")
        #expect(result.requests.last?.value(forHTTPHeaderField: "Cookie") == "auth=live")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `console domain carries a migrated session`(
        engine: ProviderPluginEngineKind) async throws
    {
        let imported = LockIsolated<[String]>([])
        let result = try await Self.fetch(
            engine: engine,
            sessions: [
                "opencode.ai": ["tracker=crumb"],
                "app.opencode.ai": ["__Host-console_session=live"],
            ],
            imported: imported)
        #expect(imported.value == ["opencode.ai", "app.opencode.ai"])
        #expect(result.usage.primary != nil)
        #expect(result.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == "__Host-console_session=live"
        })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `manual header is filtered to auth names and pinned to the primary domain`(
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(
            engine: engine,
            source: .manual,
            manualHeader: "Cookie: theme=dark; auth=manual-secret; extra=1")
        #expect(result.usage.primary != nil)
        #expect(result.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == "auth=manual-secret"
        })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `manual header without auth cookies fails before any request`(
        engine: ProviderPluginEngineKind) async
    {
        let recorded = LockIsolated<[URLRequest]>([])
        await Self.expectFailure(.missingCredential) {
            try await Self.fetch(
                engine: engine,
                source: .manual,
                manualHeader: "theme=dark",
                recordedRequests: recorded).usage
        }
        #expect(recorded.value.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `manual session rejection surfaces immediately without importing profiles`(
        engine: ProviderPluginEngineKind) async
    {
        let imported = LockIsolated<[String]>([])
        let recorded = LockIsolated<[URLRequest]>([])
        await Self.expectFailure(.authenticationExpired) {
            try await Self.fetch(
                engine: engine,
                source: .manual,
                manualHeader: "auth=dead",
                workspacesStatus: 401,
                imported: imported,
                recordedRequests: recorded).usage
        }
        #expect(imported.value.isEmpty)
        #expect(recorded.value.count == 1)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `disabled cookie source fails before resolving sessions`(
        engine: ProviderPluginEngineKind) async
    {
        let resolved = LockIsolated<[String]>([])
        await Self.expectFailure(.missingCredential) {
            try await Self.fetch(engine: engine, source: .off, resolvedDomains: resolved).usage
        }
        #expect(resolved.value.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `non credential failures retain the last error and continue to the next session`(
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(
            engine: engine,
            sessions: ["opencode.ai": ["auth=one", "auth=two"]],
            subscriptionStatusByCookie: { cookie in cookie.contains("one") ? 500 : 200 },
            billing: Self.billingSubscribedBody)
        #expect(result.usage.primary != nil)
        #expect(result.requests.count == 5)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed subscription and billing payloads surface a parse failure`(
        engine: ProviderPluginEngineKind) async
    {
        let recorded = LockIsolated<[URLRequest]>([])
        await Self.expectFailure(.parseFailure) {
            try await Self.fetch(
                engine: engine,
                subscription: "not json at all",
                billing: "also not json",
                recordedRequests: recorded).usage
        }
        // workspace GET, subscription GET, subscription POST fallback, billing GET
        #expect(recorded.value.count == 4)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `request contract sends SolidStart headers and filtered cookies`(
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetch(
            engine: engine,
            sessions: ["opencode.ai": ["auth=a; tracker=x; theme=d"]])
        #expect(result.requests.count == 2)
        for request in result.requests {
            #expect(request.value(forHTTPHeaderField: "Cookie") == "auth=a")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://opencode.ai")
            #expect(request.value(forHTTPHeaderField: "Accept")
                == "text/javascript, application/json;q=0.9, */*;q=0.8")
            #expect(request.value(forHTTPHeaderField: "X-Server-Instance")?
                .hasPrefix("server-fn:") == true)
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/") == true)
        }
        #expect(result.requests[0].value(forHTTPHeaderField: "Referer") == "https://opencode.ai")
        #expect(result.requests[0].url?.query
            == "id=def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid cached session is evicted and a fresh import succeeds in the same refresh`(
        engine: ProviderPluginEngineKind) async throws
    {
        let service = "opencode-plugin-\(UUID().uuidString)"
        Self.isolated(service) {
            CookieHeaderCache.store(
                provider: .opencode,
                scope: .providerVariant("opencode.ai"),
                cookieHeader: "auth=old",
                sourceLabel: "Profile old",
                now: Date().addingTimeInterval(-60))
        }
        let result = try await Self.fetch(
            engine: engine,
            service: service,
            sessions: ["opencode.ai": ["auth=fresh"]],
            workspacesStatusByCookie: { cookie in cookie.contains("old") ? 401 : 200 })
        #expect(result.usage.primary != nil)
        #expect(result.requests.first?.value(forHTTPHeaderField: "Cookie") == "auth=old")
        #expect(result.requests.last?.value(forHTTPHeaderField: "Cookie") == "auth=fresh")
        Self.isolated(service) {
            #expect(CookieHeaderCache.load(
                provider: .opencode,
                scope: .providerVariant("opencode.ai"))?.cookieHeader == "auth=fresh")
        }
    }

    /// The interactive cookie-refresh gate hides persisted entries and stages every cache write.
    /// Committing requires exactly one staged mutation, so a fetch that stays on one domain commits
    /// the working session while a fetch that imports both domains cannot (the broker binds each
    /// domain to its own scoped cache key). These tests pin that contract for maintainer review.
    @Test(.serialized, arguments: BundledPluginTestSupport.engines)
    func `interactive refresh commits the staged store for a single domain session`(
        engine: ProviderPluginEngineKind) async throws
    {
        let service = "opencode-plugin-\(UUID().uuidString)"
        let gate = try #require(Self.isolated(service) {
            CookieHeaderCache.beginRefreshReadSuppression(provider: .opencode)
        })
        defer { CookieHeaderCache.endRefreshReadSuppression(gate) }

        let result = try await Self.fetch(
            engine: engine,
            service: service,
            sessions: ["app.opencode.ai": ["__Host-console_session=live"]])
        #expect(result.usage.primary != nil)

        let commit = Self.isolated(service) {
            CookieHeaderCache.commitRefreshReadSuppression(gate)
        }
        #expect(commit.stagedCount == 1)
        #expect(commit.committedCount == 1)
        #expect(commit.failedCount == 0)
    }

    @Test(.serialized, arguments: BundledPluginTestSupport.engines)
    func `interactive refresh declines to commit when both domains stage imports`(
        engine: ProviderPluginEngineKind) async throws
    {
        let service = "opencode-plugin-\(UUID().uuidString)"
        let gate = try #require(Self.isolated(service) {
            CookieHeaderCache.beginRefreshReadSuppression(provider: .opencode)
        })
        defer { CookieHeaderCache.endRefreshReadSuppression(gate) }

        // The primary domain's imported candidates are staged at issue time, before the plugin
        // filters for auth cookie names, so the console-domain import is the second staged write.
        let result = try await Self.fetch(
            engine: engine,
            service: service,
            sessions: [
                "opencode.ai": ["tracker=crumb"],
                "app.opencode.ai": ["__Host-console_session=live"],
            ])
        #expect(result.usage.primary != nil)

        let commit = Self.isolated(service) {
            CookieHeaderCache.commitRefreshReadSuppression(gate)
        }
        #expect(commit.stagedCount == 2)
        #expect(commit.committedCount == 0)
        #expect(commit.failedCount == 2)
    }

    /// SolidStart returns HTTP 200 sign-in pages for expired sessions, so the body heuristic is the
    /// primary invalid-cookie signal in production and must evict the cached session.
    @Test(.serialized, arguments: BundledPluginTestSupport.engines)
    func `sign in body on a 200 response rejects the session`(
        engine: ProviderPluginEngineKind) async
    {
        let service = "opencode-plugin-\(UUID().uuidString)"
        let rejected = LockIsolated<[String]>([])
        await Self.expectFailure(.authenticationExpired) {
            try await Self.fetch(
                engine: engine,
                service: service,
                sessions: ["opencode.ai": ["auth=stale"]],
                workspaces: #"<html><title>Sign in - opencode</title><body>Please log in</body></html>"#,
                rejected: rejected).usage
        }
        #expect(rejected.value == ["opencode.ai"])
    }

    @Test(.serialized, arguments: BundledPluginTestSupport.engines)
    func `transport errors classify as network failure without entering billing fallback`(
        engine: ProviderPluginEngineKind) async
    {
        let recorded = LockIsolated<[URLRequest]>([])
        await Self.expectFailure(.networkFailure) {
            try await Self.fetch(
                engine: engine,
                transportError: URLError(.notConnectedToInternet),
                recordedRequests: recorded).usage
        }
        #expect(recorded.value.isEmpty)
    }

    @Test(.serialized, arguments: BundledPluginTestSupport.engines)
    func `transport cancellation remains cancellation`(
        engine: ProviderPluginEngineKind) async throws
    {
        await #expect(throws: CancellationError.self) {
            try await Self.fetch(engine: engine, transportError: URLError(.cancelled))
        }
    }

    @Test
    func `descriptor script values forward workspace and timeout settings`() {
        let flagged = ProviderSettingsSnapshot.make(
            opencode: .init(cookieSource: .auto, manualCookieHeader: nil, workspaceID: "wrk_set"))
        let values = OpenCodeProviderDescriptor.scriptValues(Self.context(
            environment: [ProviderPluginPrototype.environmentKey: "1"],
            settings: flagged))
        #expect(values?.settings["WORKSPACE_ID"] == "wrk_set")
        // webTimeout is a TimeInterval, so the forwarded string carries the ".0" suffix.
        #expect(values?.settings["REQUEST_TIMEOUT"] == "1.0")

        let envOnly = OpenCodeProviderDescriptor.scriptValues(Self.context(
            environment: ["CODEXBAR_OPENCODE_WORKSPACE_ID": "wrk_env"]))
        #expect(envOnly?.settings["WORKSPACE_ID"] == "wrk_env")

        let off = OpenCodeProviderDescriptor.scriptValues(Self.context(
            environment: [:],
            settings: ProviderSettingsSnapshot.make(
                opencode: .init(cookieSource: .off, manualCookieHeader: nil, workspaceID: nil))))
        #expect(off == nil)
    }

    @Test
    func `descriptor resolves the plugin strategy only behind the environment flag`() async {
        let plain = await OpenCodeProviderDescriptor.descriptor
            .fetchPlan.pipeline.resolveStrategies(Self.context(environment: [:]))
        #expect(plain.map(\.id) == ["opencode.web"])

        let flagged = await OpenCodeProviderDescriptor.descriptor
            .fetchPlan.pipeline.resolveStrategies(
                Self.context(environment: [ProviderPluginPrototype.environmentKey: "1"]))
        #expect(flagged.map(\.id) == ["opencode.js", "opencode.web"])
        #expect(await flagged[0].isAvailable(Self.context(environment: [:])) == false)
        #expect(await flagged[0].isAvailable(
            Self.context(environment: [ProviderPluginPrototype.environmentKey: "1"])) == true)

        let offSettings = ProviderSettingsSnapshot.make(
            opencode: .init(cookieSource: .off, manualCookieHeader: nil, workspaceID: nil))
        let offContext = Self.context(
            environment: [ProviderPluginPrototype.environmentKey: "1"],
            settings: offSettings)
        #expect(await flagged[0].isAvailable(offContext) == false)
    }

    // MARK: - Harness

    static func fetch(
        engine: ProviderPluginEngineKind,
        source: ProviderCookieSource = .auto,
        manualHeader: String? = nil,
        settings: [String: String] = [:],
        service: String? = nil,
        sessions: [String: [String]] = ["opencode.ai": ["auth=session"]],
        workspacesGet: String? = nil,
        workspaces: String = workspacesBody,
        workspacesStatus: Int = 200,
        workspacesStatusByCookie: (@Sendable (String) -> Int)? = nil,
        subscription: String = subscriptionBody,
        subscriptionStatus: Int = 200,
        subscriptionStatusByCookie: (@Sendable (String) -> Int)? = nil,
        billing: String = billingSolidBody,
        transportError: (any Error)? = nil,
        imported: LockIsolated<[String]>? = nil,
        rejected: LockIsolated<[String]>? = nil,
        resolvedDomains: LockIsolated<[String]>? = nil,
        recordedRequests: LockIsolated<[URLRequest]>? = nil)
        async throws -> (usage: UsageSnapshot, requests: [URLRequest])
    {
        let service = service ?? "opencode-plugin-\(UUID().uuidString)"
        let broker = ProviderPluginCookieBroker(
            provider: .opencode,
            domains: ["opencode.ai", "app.opencode.ai"],
            settings: .init(cookieSource: source, manualCookieHeader: manualHeader),
            importer: { domain in
                imported?.setValue((imported?.value ?? []) + [domain])
                if source == .manual {
                    Issue.record("Manual mode must never import a browser profile")
                }
                return (sessions[domain] ?? []).enumerated().map {
                    (header: $0.element, source: "Profile \($0.offset) / \(domain)")
                }
            })
        let transport = ProviderHTTPTransportStub { request in
            if let transportError { throw transportError }
            recordedRequests?.setValue((recordedRequests?.value ?? []) + [request])
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let serverID = request.value(forHTTPHeaderField: "X-Server-Id")
            var status = 200
            let body: String
            switch serverID {
            case "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f":
                status = workspacesStatusByCookie?(cookie) ?? workspacesStatus
                let workspacesText = request.httpMethod == "GET"
                    ? (workspacesGet ?? workspaces)
                    : workspaces
                body = status == 200 ? workspacesText : Self.serverErrorBody
            case "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4":
                status = subscriptionStatusByCookie?(cookie) ?? subscriptionStatus
                body = status == 200 ? subscription : Self.serverErrorBody
            case "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d":
                body = billing
            default:
                throw URLError(.badURL)
            }
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
        let runtime = try BundledPluginTestSupport.runtime("opencode", engine: engine, transport: transport)
        let resolver: ProviderPluginRuntime.CookieSessionResolver = { domain, cachedOnly in
            resolvedDomains?.setValue((resolvedDomains?.value ?? []) + [domain])
            return try Self.isolated(service) {
                try broker.nextSession(domain: domain, cachedOnly: cachedOnly)
            }
        }
        let invalidator: ProviderPluginRuntime.CookieSessionInvalidator = { domain, id in
            rejected?.setValue((rejected?.value ?? []) + [domain])
            Self.isolated(service) { broker.rejectCookie(domain: domain, id: id) }
        }
        let usage = try await runtime.fetchUsage(
            settings: settings,
            now: Self.now,
            cookieSource: source,
            cookieSessionResolver: resolver,
            cookieSessionInvalidator: invalidator)
        return await (usage, transport.requests())
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected classified provider failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Expected classified provider failure, got \(error)")
        }
    }

    private static func context(
        environment: [String: String],
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .web,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: settings,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: OpenCodePluginClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private static func isolated<T>(_ service: String, operation: () throws -> T) rethrows -> T {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        return try KeychainCacheStore.withImplicitTestStoreForTesting {
            try KeychainCacheStore.withServiceOverrideForTesting(service) {
                try CookieHeaderCache.withLegacyBaseURLOverrideForTesting(base, operation: operation)
            }
        }
    }
}

private struct OpenCodePluginClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String {
        "unused"
    }

    func detectVersion() -> String? {
        nil
    }
}
