import Foundation
#if os(macOS)
import Security
#endif
import SweetCookieKit
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ProviderPluginCookieResultTests {
    @Test(arguments: [true, false])
    func `only a successful nonpersistent script fetch validates an empty refresh`(authenticated: Bool) async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let strategy = ScriptFetchStrategy(
            id: "lithosai.fixture",
            provider: .lithosai,
            bundledPlugin: "lithosai",
            sourceLabel: "web",
            kind: .web,
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                let body: String
                let code: Int
                switch url.path {
                case "/api/me":
                    code = 200
                    body = #"{"user":{},"activeOrganization":{"id":"fixture-org"}}"#
                case "/api/billing":
                    code = authenticated ? 200 : 401
                    body = #"{"balanceNanos":2570000000,"hasCard":true,"onHold":false}"#
                default:
                    code = 503
                    body = "{}"
                }
                return try (Data(body.utf8), #require(HTTPURLResponse(
                    url: url, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
            },
            resolveValues: { _ in .init() },
            isEnabled: { _ in true })
        let context = ProviderCutoverTestSupport.context(settings: ProviderSettingsSnapshot(
            CookieProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: "__Host-console_session=fixture; __Host-console_csrf=fixture-csrf"),
            for: LithosAIProviderSettingsKey.self))
        try await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
            let gate = try #require(CookieHeaderCache.beginRefreshReadSuppression(provider: .lithosai))
            defer { CookieHeaderCache.endRefreshReadSuppression(gate) }
            do {
                let result = try await strategy.fetch(context)
                #expect(authenticated)
                #expect(result.usage.detailRow(label: "Balance")?.value == "$2.57")
            } catch let error as ProviderFetchClassifiedError {
                #expect(!authenticated)
                #expect(error.kind == .authenticationExpired)
            }
            let commit = CookieHeaderCache.commitRefreshReadSuppression(gate)
            #expect(commit.stagedCount == 0)
            #expect(commit.failedCount == (authenticated ? 0 : 1))
            #expect(CookieHeaderCache.load(provider: .lithosai) == nil)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines, [false, true])
    func `plugin importers retain the explicit interaction across engine callbacks`(
        engine: ProviderPluginEngineKind, jar: Bool) async throws
    {
        let domain = "fixture-\(UUID().uuidString.lowercased()).example.test"
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        defer {
            _ = CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
                CookieHeaderCache.clear(provider: .lithosai, scope: .providerVariant(domain))
            }
        }
        let runtime = try ProviderPluginRuntime(source: """
        defineProvider({id: 'lithosai', name: 'Fixture', endpoints: ['https://\(domain)'], settings: [],
          capabilities: ['browser-cookies'], cookieDomains: ['\(domain)'],
          async fetchUsage(ctx) {
            for await (const session of ctx.browser.sessions('\(domain)')) {
              return {primary: {usedPercent: 42}};
            }
            throw new Error('No session');
          }
        });
        """, engine: engine)
        try await ProviderInteractionContext.$current.withValue(.userInitiated) {
            try await BrowserCookieAccessGate.withExplicitRetry {
                let importJar: ProviderPluginCookieBroker.JarImporter = { batch in
                    #expect(ProviderInteractionContext.current == .userInitiated)
                    return batch == 0 ? [ProviderPluginCookieSession(header: "", source: "Chrome", origin: "")] : nil
                }
                let broker = ProviderPluginCookieBroker(
                    provider: .lithosai,
                    domains: [domain, "unused.example.test"],
                    settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                    batches: { _, batch in
                        #expect(ProviderInteractionContext.current == .userInitiated)
                        return batch == 0 ? [("session=fixture", "Chrome")] : nil
                    },
                    jarImporter: jar ? importJar : nil)
                let usage = try await runtime.fetchUsage(cookieSessionResolver: { domain, cachedOnly in
                    try CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
                        try broker.nextSession(domain: domain, cachedOnly: cachedOnly)
                    }
                })
                #expect(usage.primary?.usedPercent == 42)
                if !jar {
                    #expect(CookieHeaderCache.load(provider: .lithosai, scope: .providerVariant(domain))?
                        .cookieHeader == "session=fixture")
                }
            }
        }
    }

    #if os(macOS)
    @Test(arguments: BundledPluginTestSupport.engines)
    func `plugin fetch tasks keep separate witnesses when an importer reports a keychain status`(
        engine: ProviderPluginEngineKind) async throws
    {
        let domain = "fixture-\(UUID().uuidString.lowercased()).example.test"
        let source = """
        defineProvider({id: 'lithosai', name: 'Fixture', endpoints: ['https://\(domain)'], settings: [],
          capabilities: ['browser-cookies'], cookieDomains: ['\(domain)'],
          async fetchUsage(ctx) {
            for await (const session of ctx.browser.sessions('\(domain)')) {
              return {primary: {usedPercent: 42}};
            }
            throw new Error('No session');
          }
        });
        """
        func fetch(importerStatus: OSStatus) async throws -> Bool {
            let runtime = try ProviderPluginRuntime(source: source, engine: engine)
            let (usage, observed) = await CLIUsageCache.observingLockedKeychain {
                let broker = ProviderPluginCookieBroker(
                    provider: .lithosai,
                    domains: [domain],
                    settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                    batches: { _, _ in nil },
                    jarImporter: { batch in
                        KeychainLockWitness.note(importerStatus)
                        return batch == 0 ? [ProviderPluginCookieSession(header: "", source: "Chrome", origin: "")] :
                            nil
                    })
                return try? await runtime.fetchUsage(cookieSessionResolver: { domain, cachedOnly in
                    try broker.nextSession(domain: domain, cachedOnly: cachedOnly)
                })
            }
            #expect(usage?.primary?.usedPercent == 42)
            return observed
        }
        // Concurrent fetches keep their own witness: only the locked one observes it.
        async let locked = fetch(importerStatus: errSecInteractionNotAllowed)
        async let other = fetch(importerStatus: errSecItemNotFound)
        let (lockedObserved, otherObserved) = try await (locked, other)
        #expect(lockedObserved)
        #expect(!otherObserved)
    }
    #endif

    @Test(arguments: BundledPluginTestSupport.engines, [
        UsageProvider.lithosai, .museai, .abacus, .helmcode, .qoder, .parallel,
    ])
    func `suppressed plugin imports explain permission recovery instead of missing login`(
        engine: ProviderPluginEngineKind, provider: UsageProvider) async throws
    {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let runtime = try Self.missingSessionRuntime(plugin: provider.rawValue, engine: engine, storage: storage)
        let detection = BrowserDetection(
            homeDirectory: "/synthetic-cookie-home",
            cacheTTL: 0,
            now: Date.init,
            fileExists: { $0.contains("/Google/Chrome") || $0.contains("/Google Chrome.app") },
            directoryContents: { _ in ["Default"] },
            applicationURLs: { _ in [] },
            profileAccessIssue: { _ in nil })
        let importJar: ProviderPluginCookieBroker.JarImporter = { batch in
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                try BrowserCookieAccessGate.withShouldAttemptOverrideForTesting(false) {
                    try ProviderPluginCookieBroker.importCookieJars(
                        provider: provider,
                        domains: runtime.manifest.cookieDomains,
                        browserDetection: detection,
                        batch: batch)
                }
            }
        }
        let broker = ProviderPluginCookieBroker(
            provider: provider,
            domains: runtime.manifest.cookieDomains,
            settings: .init(cookieSource: .auto, manualCookieHeader: nil),
            batches: { domain, batch in
                try KeychainAccessGate.withTaskOverrideForTesting(false) {
                    try BrowserCookieAccessGate.withShouldAttemptOverrideForTesting(false) {
                        if provider == .abacus {
                            guard batch == 0 else { return nil }
                            return AbacusCookieImporter.importSessions(browserDetection: detection)
                                .map { ($0.cookieHeader, $0.sourceLabel) }
                        }
                        return try ProviderPluginCookieBroker.importCookieHeaders(
                            provider: provider, domain: domain, browserDetection: detection, batch: batch)
                    }
                }
            },
            jarImporter: runtime.manifest.usesCookieJar ? importJar : nil,
            policy: runtime.manifest.cookiePolicy)
        do {
            _ = try await runtime.fetchUsage(cookieSessionResolver: { domain, cachedOnly in
                try CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
                    try broker.nextSession(domain: domain, cachedOnly: cachedOnly)
                }
            }, cookieResolver: { _, domain in
                try CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
                    try broker.cookieHeader(domain: domain)
                }
            })
            Issue.record("Expected browser permission failure")
        } catch {
            let failure = broker.preferredFailure(over: error)
            #expect((failure as? ProviderFetchClassifiedError)?.kind == .permissionDenied)
            #expect(failure.localizedDescription.contains("cookie access needs Keychain permission"))
            #expect(failure.localizedDescription.contains("Refresh beside Cookie source"))
            #expect(failure.localizedDescription.contains("provider menu"))
            #expect(failure.localizedDescription.contains("Manual"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines, [UsageProvider.museai, .perplexity, .opencode])
    func `plugin browser names follow each provider catalog subset`(
        engine: ProviderPluginEngineKind, provider: UsageProvider) async throws
    {
        let runtime = try ProviderPluginRuntime(source: """
        defineProvider({id: '\(provider.rawValue)', name: 'Fixture',
          endpoints: ['https://cookies.example.test'],
          settings: [{key: 'EXPECTED_BROWSERS', title: 'Fixture browsers', type: 'plain'}],
          async fetchUsage(ctx) {
            if (ctx.browser.supportedBrowsers !== ctx.settings.get('EXPECTED_BROWSERS')) {
              throw new Error('Browser names do not match the provider policy');
            }
            return {primary: {usedPercent: 0}};
          }
        });
        """, engine: engine)
        let order = ProviderDefaults.metadata[provider]?.browserCookieOrder ?? Browser.defaultImportOrder
        if provider != .opencode {
            for name in ["Aside", "Opera", "Opera Neon"] {
                #expect(order.map(\.displayName).contains(name))
            }
        }
        let usage = try await runtime.fetchUsage(settings: ["EXPECTED_BROWSERS": order.map(\.displayName)
                .joined(separator: ", ")])
        #expect(usage.primary?.usedPercent == 0)
    }

    @Test(arguments: BundledPluginTestSupport.engines, [UsageProvider.museai, .abacus, .parallel])
    func `missing plugin session explains the automatic browser boundary`(
        engine: ProviderPluginEngineKind, provider: UsageProvider) async throws
    {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let runtime = try Self.missingSessionRuntime(plugin: provider.rawValue, engine: engine, storage: storage)
        do {
            _ = try await runtime.fetchUsage(cookieSessionResolver: { _, _ in nil })
            Issue.record("Expected missing session")
        } catch {
            let order = ProviderDefaults.metadata[provider]?.browserCookieOrder ?? Browser.defaultImportOrder
            #expect(error.localizedDescription
                .contains("Supported browsers: \(order.map(\.displayName).joined(separator: ", "))."))
            #expect(error.localizedDescription.localizedCaseInsensitiveContains("cookie header"))
        }
    }

    static func missingSessionRuntime(
        plugin: String = "museai", engine: ProviderPluginEngineKind, storage: URL) throws -> ProviderPluginRuntime
    {
        let url = try #require(CodexBarCoreResources.bundle?.url(forResource: plugin, withExtension: "js"))
        return try ProviderPluginRuntime(
            source: String(contentsOf: url, encoding: .utf8),
            transport: ProviderHTTPTransportHandler { _ in
                Issue.record("Missing sessions must not issue HTTP requests")
                throw URLError(.badURL)
            },
            engine: engine,
            storageDirectory: storage)
    }

    @Test(arguments: BundledPluginTestSupport.engines, [false, true])
    func `both result entry points preserve cookie iteration and rejection`(
        engine: ProviderPluginEngineKind,
        usageOnly: Bool) async throws
    {
        let requests = LockIsolated<[Bool]>([])
        let rejections = LockIsolated<[String]>([])
        let runtime = try ProviderPluginRuntime(source: """
        defineProvider({id: 'fireworks', name: 'Fixture', endpoints: ['https://cookies.example.test'], settings: [],
          capabilities: ['browser-cookies'], cookieDomains: ['cookies.example.test'],
          async fetchUsage(ctx) {
            if (ctx.browser.availability('cookies.example.test') !== 'available') {
              throw new Error('Session resolver is unavailable');
            }
            for await (const session of ctx.browser.sessions('cookies.example.test', {cachedOnly: true})) {
              ctx.browser.rejectCookie('cookies.example.test', session);
            }
            for await (const session of ctx.browser.sessions('cookies.example.test')) {
              return {usage: {primary: {usedPercent: 42}}, sourceLabel: session.source,
                persist: {ACCOUNT_SLUG: 'fixture-team'}};
            }
            throw new Error('No session candidates');
          }
        });
        """, engine: engine)
        let resolve: ProviderPluginRuntime.CookieSessionResolver = { domain, cachedOnly in
            #expect(domain == "cookies.example.test")
            requests.setValue(requests.value + [cachedOnly])
            if requests.value.count == 2 { return nil }
            return ProviderPluginCookieSession(
                header: "session=fixture",
                source: cachedOnly ? "Cache" : "Profile",
                origin: "https://cookies.example.test",
                id: cachedOnly ? "rejected-candidate" : "accepted-candidate")
        }
        let reject: ProviderPluginRuntime.CookieSessionInvalidator = { domain, id in
            rejections.setValue(rejections.value + ["\(domain):\(id)"])
        }
        let usage: UsageSnapshot
        if usageOnly {
            usage = try await runtime.fetchUsage(cookieSessionResolver: resolve, cookieSessionInvalidator: reject)
        } else {
            let result = try await runtime.fetchResult(cookieSessionResolver: resolve, cookieSessionInvalidator: reject)
            #expect(result.sourceLabel == "Profile")
            #expect(result.persist == ["ACCOUNT_SLUG": "fixture-team"])
            usage = result.usage
        }
        #expect(usage.primary?.usedPercent == 42)
        #expect(requests.value == [true, true, false])
        #expect(rejections.value == ["cookies.example.test:rejected-candidate"])
    }
}
