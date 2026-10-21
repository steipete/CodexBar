import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct ProviderPluginCookieBrokerTests {
    private let domains: Set<String> = ["cloud.example.test", "community.example.test"]

    @Test
    func `denied synthetic profile reports Files and Folders instead of sign in`() throws {
        try self.isolated {
            let detection = BrowserDetection(
                homeDirectory: "/synthetic-cookie-home",
                cacheTTL: 0,
                now: Date.init,
                fileExists: { $0 == "/Applications/Google Chrome.app" },
                directoryContents: { _ in nil },
                applicationURLs: { _ in [] },
                profileAccessIssue: { _ in .accessDenied })
            let context = ProviderFetchContext(
                runtime: .app,
                sourceMode: .web,
                includeCredits: false,
                webTimeout: 1,
                webDebugDumpHTML: false,
                verbose: false,
                env: [:],
                settings: nil,
                fetcher: UsageFetcher(),
                claudeFetcher: ClaudeUsageFetcher(browserDetection: detection),
                browserDetection: detection)
            let broker = ProviderPluginCookieBroker(provider: .xapi, domains: ["console.x.com"], context: context)
            let session = try KeychainAccessGate.withTaskOverrideForTesting(false) {
                try broker.nextSession(domain: "console.x.com")
            }
            #expect(session == nil)
            let missing = ProviderFetchClassifiedError(kind: .missingCredential, message: "Synthetic sign in")
            let failure = try #require(broker.preferredFailure(over: missing) as? ProviderFetchClassifiedError)
            #expect(failure.kind == .permissionDenied)
            #expect(failure.message.contains("Files & Folders"))
            #expect(failure.message.contains(Browser.chrome.displayName))
            let apiError = ProviderFetchClassifiedError(kind: .apiFailure, message: "Synthetic API error")
            #expect((broker.preferredFailure(over: apiError) as? ProviderFetchClassifiedError)?.kind == .apiFailure)
        }
    }

    @Test
    func `policy blocked jar imports do not report profile permissions`() throws {
        try self.isolated {
            let runtime = try BundledPluginTestSupport.runtime(
                "longcat", engine: .quickJS, transport: ProviderHTTPTransportStub { _ in
                    Issue.record("No network request is expected")
                    throw URLError(.unsupportedURL)
                })
            let detection = BrowserDetection(
                homeDirectory: "/synthetic-cookie-home",
                cacheTTL: 0,
                now: Date.init,
                fileExists: { _ in Issue.record("Policy must block discovery"); return false },
                directoryContents: { _ in Issue.record("Policy must block discovery"); return nil },
                applicationURLs: { _ in [] },
                profileAccessIssue: { _ in Issue.record("Policy must block profile probes"); return .accessDenied })
            for mode in [ProviderRuntime.cli, .app] {
                let context = ProviderFetchContext(
                    runtime: mode,
                    sourceMode: .web,
                    includeCredits: false,
                    webTimeout: 1,
                    webDebugDumpHTML: false,
                    verbose: false,
                    env: [:],
                    settings: nil,
                    fetcher: UsageFetcher(),
                    claudeFetcher: ClaudeUsageFetcher(browserDetection: detection),
                    browserDetection: detection)
                try ProviderInteractionContext.$current.withValue(.background) {
                    let broker = ProviderPluginCookieBroker(
                        provider: .longcat,
                        domains: runtime.manifest.cookieDomains,
                        context: context,
                        policy: runtime.manifest.cookiePolicy)
                    let session = try broker.nextSession(domain: "longcat.chat")
                    #expect(session == nil)
                    let missing = ProviderFetchClassifiedError(kind: .missingCredential, message: "Synthetic sign in")
                    #expect((broker.preferredFailure(over: missing) as? ProviderFetchClassifiedError)?.kind
                        == .missingCredential)
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func `different browser permission failures both remain actionable`(reversed: Bool) throws {
        try self.isolated {
            let broker = ProviderPluginCookieBroker(
                provider: .manus,
                domains: self.domains,
                settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                batches: { _, _ in
                    if reversed {
                        BrowserCookieAccessGate.recordAccessFailure(for: .chrome, profileDenied: true)
                        BrowserCookieAccessGate.recordAccessFailure(for: .safari)
                    } else {
                        BrowserCookieAccessGate.recordAccessFailure(for: .safari)
                        BrowserCookieAccessGate.recordAccessFailure(for: .chrome, profileDenied: true)
                    }
                    return nil
                })
            let session = try broker.nextSession(domain: "cloud.example.test")
            #expect(session == nil)
            let missing = ProviderFetchClassifiedError(kind: .missingCredential, message: "Synthetic sign in")
            let failure = try #require(broker.preferredFailure(over: missing) as? ProviderFetchClassifiedError)
            #expect(failure.kind == .permissionDenied)
            #expect(failure.message.hasPrefix("Cannot read \(Browser.chrome.displayName)'s profile"))
            #expect(failure.message.contains("Files & Folders"))
            #expect(failure.message.contains("Safari"))
            #expect(failure.message.contains("Full Disk Access"))
        }
    }

    @Test(arguments: [false, true])
    func `decryption denial takes precedence for the same browser`(reversed: Bool) throws {
        try self.isolated {
            let broker = ProviderPluginCookieBroker(
                provider: .manus,
                domains: self.domains,
                settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                batches: { _, _ in
                    if reversed {
                        BrowserCookieAccessGate.recordAccessFailure(for: .chrome)
                        BrowserCookieAccessGate.recordAccessFailure(for: .chrome, profileDenied: true)
                    } else {
                        BrowserCookieAccessGate.recordAccessFailure(for: .chrome, profileDenied: true)
                        BrowserCookieAccessGate.recordAccessFailure(for: .chrome)
                    }
                    return nil
                })
            #expect(try broker.nextSession(domain: "cloud.example.test") == nil)
            let missing = ProviderFetchClassifiedError(kind: .missingCredential, message: "Synthetic sign in")
            let failure = try #require(broker.preferredFailure(over: missing) as? ProviderFetchClassifiedError)
            #expect(failure.message.contains("Keychain permission"))
            #expect(!failure.message.contains("Files & Folders"))
        }
    }

    @Test
    func `Safari profile denial points to Full Disk Access`() throws {
        try self.isolated {
            let broker = ProviderPluginCookieBroker(
                provider: .manus,
                domains: self.domains,
                settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                batches: { _, _ in
                    BrowserCookieAccessGate.recordAccessFailure(for: .safari, profileDenied: true)
                    return nil
                })
            #expect(try broker.nextSession(domain: "cloud.example.test") == nil)
            let missing = ProviderFetchClassifiedError(kind: .missingCredential, message: "Synthetic sign in")
            let failure = try #require(broker.preferredFailure(over: missing) as? ProviderFetchClassifiedError)
            #expect(failure.message.contains("Full Disk Access"))
            #expect(!failure.message.contains("Files & Folders"))
        }
    }

    @Test
    func `suppressed browsers leave an empty batch instead of ending traversal`() throws {
        let detection = BrowserDetection(
            homeDirectory: "/synthetic-cookie-home",
            cacheTTL: 0,
            now: { Date(timeIntervalSince1970: 0) },
            fileExists: { _ in false },
            directoryContents: { _ in nil },
            applicationURLs: { _ in [] },
            profileAccessIssue: { _ in nil })
        try BrowserCookieAccessGate.withShouldAttemptOverrideForTesting(false) {
            let headers = try ProviderPluginCookieBroker.importCookieHeaders(
                provider: .mimo, domain: "platform.xiaomimimo.com", browserDetection: detection, batch: 1)
            let jars = try ProviderPluginCookieBroker.importCookieJars(
                provider: .mimo, domains: ["platform.xiaomimimo.com"], browserDetection: detection, batch: 1)
            #expect(headers?.isEmpty == true)
            #expect(jars?.isEmpty == true)
        }
    }

    @Test
    func `denied batches retain later sessions and do not replace API failures`() throws {
        try self.isolated {
            let broker = ProviderPluginCookieBroker(
                provider: .manus,
                domains: self.domains,
                settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                batches: { _, batch in
                    if batch == 0 {
                        throw BrowserCookieError.accessDenied(browser: .safari, details: "Synthetic denial")
                    }
                    return batch == 1 ? [("session=fallback", "Fixture")] : nil
                })
            let session = try #require(try broker.nextSession(domain: "cloud.example.test"))
            #expect(session.header == "session=fallback")
            let apiError = ProviderFetchClassifiedError(kind: .apiFailure, message: "Synthetic server failure")
            #expect((broker.preferredFailure(over: apiError) as? ProviderFetchClassifiedError)?.kind == .apiFailure)
        }
    }

    @Test
    func `China manual capture is never issued for global domain`() throws {
        let snapshot = ProviderSettingsSnapshot.make(qoder: .init(
            cookieSource: .manual,
            manualCookieHeader: "curl https://qoder.com.cn -H 'Cookie: session=china-fixture'"))
        let settings = try #require(QoderProviderDescriptor.descriptor.settingsSection.cookieSettings(from: snapshot))
        let broker = ProviderPluginCookieBroker(
            provider: .qoder,
            domains: ["qoder.com", "qoder.com.cn"],
            settings: settings,
            importer: { _ in throw URLError(.unknown) })
        #expect(throws: ProviderPluginError.self) { try broker.cookieHeader(domain: "qoder.com") }
        #expect(try broker.cookieHeader(domain: "qoder.com.cn") == "session=china-fixture")
    }

    @Test
    func `rejected cached cookie advances to browser session`() throws {
        try self.isolated { () throws in
            let domain = "cloud.example.test"
            CookieHeaderCache.store(
                provider: .manus,
                scope: .providerVariant(domain),
                cookieHeader: "session=stale",
                sourceLabel: "Fixture")
            let broker = self.broker()
            #expect(try broker.cookieHeader(domain: domain) == "session=stale")
            broker.rejectCookie(domain: domain)
            #expect(CookieHeaderCache.load(provider: .manus, scope: .providerVariant(domain)) == nil)
            #expect(try broker.cookieHeader(domain: domain) == "session=\(domain)")
        }
    }

    @Test
    func `two domains import and cache independent sessions`() throws {
        try self.isolated { () throws in
            let broker = self.broker()
            CookieHeaderCache.store(provider: .manus, cookieHeader: "session=legacy", sourceLabel: "Fixture")
            for domain in self.domains {
                #expect(try broker.cookieHeader(domain: domain) == "session=\(domain)")
                #expect(CookieHeaderCache.load(
                    provider: .manus,
                    scope: .providerVariant(domain))?.cookieHeader
                    == "session=\(domain)")
            }
            let cached = self.broker(importer: { _ in
                Issue.record("A cached domain must not import cookies")
                throw URLError(.unknown)
            })
            for domain in self.domains {
                #expect(try cached.cookieHeader(domain: domain) == "session=\(domain)")
            }
        }
    }

    @Test
    func `rejection evicts only the observed domain and preserves newer sessions`() throws {
        try self.isolated { () throws in
            let broker = self.broker()
            for domain in self.domains {
                _ = try broker.cookieHeader(domain: domain)
            }
            broker.rejectCookie(domain: "cloud.example.test")
            #expect(CookieHeaderCache.load(
                provider: .manus,
                scope: .providerVariant("cloud.example.test")) == nil)
            #expect(CookieHeaderCache.load(
                provider: .manus,
                scope: .providerVariant("community.example.test")) != nil)
            CookieHeaderCache.store(
                provider: .manus,
                scope: .providerVariant("community.example.test"),
                cookieHeader: "session=newer",
                sourceLabel: "Fixture")
            // A second lookup in the same fetch must not retarget an outstanding rejection.
            #expect(try broker.cookieHeader(domain: "community.example.test") == "session=community.example.test")
            broker.rejectCookie(domain: "community.example.test")
            broker.rejectCookie(domain: "community.example.test")
            #expect(CookieHeaderCache.load(
                provider: .manus,
                scope: .providerVariant("community.example.test"))?.cookieHeader == "session=newer")
        }
    }

    @Test
    func `failed import persistence still pins the issued session`() throws {
        try self.isolated { () throws in
            let broker = self.broker()
            let domain = "cloud.example.test"
            let issued = try KeychainCacheStore.withStoreFailureStatusOverrideForTesting(-25308) {
                try broker.cookieHeader(domain: domain)
            }
            #expect(CookieHeaderCache.load(
                provider: .manus,
                scope: .providerVariant(domain)) == nil)
            CookieHeaderCache.store(
                provider: .manus,
                scope: .providerVariant(domain),
                cookieHeader: "session=newer",
                sourceLabel: "Fixture")
            #expect(try broker.cookieHeader(domain: domain) == issued)
            broker.rejectCookie(domain: domain)
            #expect(CookieHeaderCache.load(
                provider: .manus,
                scope: .providerVariant(domain))?
                .cookieHeader == "session=newer")
        }
    }

    @Test(arguments: [ProviderCookieSource.off, .manual])
    func `manual and off do not import or mutate cached sessions`(source: ProviderCookieSource) throws {
        try self.isolated { () throws in
            let broker = self.broker(source: source, importer: { _ in
                Issue.record("Manual and Off must not import")
                throw URLError(.unknown)
            })
            for domain in self.domains.sorted() {
                CookieHeaderCache.store(
                    provider: .manus,
                    scope: .providerVariant(domain),
                    cookieHeader: "session=cached",
                    sourceLabel: "Fixture")
                if source == .manual, domain == self.domains.min() {
                    #expect(try broker.cookieHeader(domain: domain) == "session=manual")
                } else {
                    #expect(throws: ProviderPluginError.self) { try broker.cookieHeader(domain: domain) }
                }
                broker.rejectCookie(domain: domain)
                #expect(CookieHeaderCache.load(
                    provider: .manus,
                    scope: .providerVariant(domain)) != nil)
            }
        }
    }

    @Test
    func `single domain retains its existing cache and undeclared domains fail closed`() throws {
        try self.isolated { () throws in
            CookieHeaderCache.store(provider: .manus, cookieHeader: "session=existing", sourceLabel: "Fixture")
            let broker = ProviderPluginCookieBroker(
                provider: .manus,
                domains: ["cloud.example.test"],
                settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                importer: { _ in throw URLError(.unknown) })
            #expect(try broker.cookieHeader(domain: "cloud.example.test") == "session=existing")
            #expect(throws: ProviderPluginError.self) { try broker.cookieHeader(domain: "undeclared.test") }
        }
    }

    @Test
    func `candidate order skips duplicates and late rejection cannot evict successor`() throws {
        try self.isolated { () throws in
            let domain = "cloud.example.test"
            let scope = CookieHeaderCache.Scope.providerVariant(domain)
            CookieHeaderCache.store(
                provider: .manus,
                scope: scope,
                cookieHeader: "session=cached",
                sourceLabel: "Cached")
            let imports = LockIsolated(0)
            let broker = self.broker(importer: { _ in
                imports.setValue(imports.value + 1)
                return [
                    ("session=cached", "Duplicate"),
                    ("session=first", "Profile 1"),
                    ("session=second", "Profile 2"),
                ]
            })
            let cached = try #require(try broker.nextSession(domain: domain))
            #expect(cached.header == "session=cached")
            #expect(cached.source == "Cached")
            #expect(imports.value == 0)
            broker.rejectCookie(domain: domain, id: cached.id)
            #expect(CookieHeaderCache.load(provider: .manus, scope: scope) == nil)
            let first = try #require(try broker.nextSession(domain: domain))
            let second = try #require(try broker.nextSession(domain: domain))
            #expect(first.source == "Profile 1")
            #expect(second.source == "Profile 2")
            #expect(first.origin == "https://\(domain)")
            #expect(imports.value == 1)
            let otherDomain = "community.example.test"
            let other = try #require(try broker.nextSession(domain: otherDomain))
            broker.rejectCookie(domain: domain, id: other.id)
            #expect(CookieHeaderCache.load(provider: .manus, scope: scope)?.cookieHeader == second.header)
            #expect(CookieHeaderCache.load(
                provider: .manus,
                scope: .providerVariant(otherDomain))?.cookieHeader == other.header)
            broker.rejectCookie(domain: domain, id: first.id)
            #expect(CookieHeaderCache.load(provider: .manus, scope: scope)?.cookieHeader == second.header)
            #expect(try broker.nextSession(domain: domain) == nil)
            broker.rejectCookie(domain: domain, id: second.id)
            #expect(CookieHeaderCache.load(provider: .manus, scope: scope) == nil)
        }
    }

    @Test
    func `legacy regional cache is bound by its authoritative source suffix`() throws {
        try self.isolated { () throws in
            CookieHeaderCache.store(
                provider: .qoder,
                cookieHeader: "session=china",
                sourceLabel: "Chrome / qoder.com.cn")
            let broker = ProviderPluginCookieBroker(
                provider: .qoder,
                domains: ["qoder.com", "qoder.com.cn"],
                settings: .init(
                    cookieSource: .auto,
                    manualCookieHeader: nil),
                importer: { _ in [] })
            #expect(try broker.nextSession(domain: "qoder.com") == nil)
            let china = try #require(try broker.nextSession(domain: "qoder.com.cn"))
            #expect(china.header == "session=china")
            broker.rejectCookie(domain: "qoder.com.cn", id: china.id)
            #expect(CookieHeaderCache.load(provider: .qoder) == nil)
        }
    }

    @Test
    func `browser domain filtering excludes other regions and lookalikes`() {
        for domain in [".qoder.com.cn", "www.qoder.com.cn", "not-qoder.com", "qoder.com.evil.test"] {
            #expect(!ProviderPluginCookieBroker.matches(cookieDomain: domain, domain: "qoder.com"))
        }
        #expect(ProviderPluginCookieBroker.matches(cookieDomain: ".perplexity.ai", domain: "www.perplexity.ai"))
        #expect(ProviderPluginCookieBroker.matches(cookieDomain: ".www.qoder.com.cn", domain: "qoder.com.cn"))
        #if os(macOS)
        #expect(ProviderPluginCookieBroker.cookieQuery(domain: "qoder.com").domainMatch == .exact)
        #expect(ProviderPluginCookieBroker.cookieQuery(domain: "www.perplexity.ai").domains == [
            "www.perplexity.ai",
            "perplexity.ai",
        ])
        #endif
    }

    #if os(macOS)
    @Test(arguments: [false, true])
    func `exact host cookie wins over parent without accepting sibling or lookalike hosts`(reversed: Bool) throws {
        let rows = [
            (".example.test", "parent"),
            ("www.example.test", "host"),
            ("backend.example.test", "sibling"),
            ("www.example.test.evil.test", "lookalike"),
        ]
        let cookies = try rows.map { domain, value in
            try #require(HTTPCookie(properties: [
                .domain: domain, .path: "/", .name: "session", .value: value, .secure: true,
            ]))
        }
        let selected = ProviderPluginCookieBroker.cookiesForRequest(
            reversed ? Array(cookies.reversed()) : cookies, domain: "www.example.test")
        #expect(selected.map(\.value) == ["host"])
        let parent = ProviderPluginCookieBroker.cookiesForRequest(cookies, domain: "example.test")
        #expect(parent.map(\.value) == ["parent"])
    }
    #endif

    @Test
    func `browser batches advance only after earlier candidates are consumed`() throws {
        try self.isolated { () throws in
            let batches = BatchCalls()
            let broker = ProviderPluginCookieBroker(
                provider: .abacus,
                domains: ["apps.abacus.ai"],
                settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                batches: { _, batch in
                    batches.append(batch)
                    return switch batch {
                    case 0: [("session=chrome", "Chrome")]
                    case 1: [("session=chrome", "Duplicate"), ("session=firefox", "Firefox")]
                    default: nil
                    }
                })
            let chrome = try #require(try broker.nextSession(domain: "apps.abacus.ai"))
            #expect(chrome.header == "session=chrome")
            #expect(batches.values == [0])
            broker.rejectCookie(domain: "apps.abacus.ai", id: chrome.id)
            #expect(try broker.nextSession(domain: "apps.abacus.ai")?.header == "session=firefox")
            #expect(batches.values == [0, 1])
            #expect(try broker.nextSession(domain: "apps.abacus.ai") == nil)
            #expect(try broker.nextSession(domain: "apps.abacus.ai") == nil)
            #expect(batches.values == [0, 1, 2])
        }
    }

    @Test
    func `empty first browser batch still reaches later browsers`() throws {
        try self.isolated { () throws in
            let broker = ProviderPluginCookieBroker(
                provider: .abacus,
                domains: ["apps.abacus.ai"],
                settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                batches: { _, batch in batch == 0 ? [] : batch == 1 ? [("session=fresh", "Fixture")] : nil })
            #expect(try broker.nextSession(domain: "apps.abacus.ai")?.header == "session=fresh")
        }
    }

    @Test
    func `jar imports advance one browser only after rejection`() throws {
        try self.isolated {
            let batches = BatchCalls()
            let domain = "apps.abacus.ai"
            let broker = ProviderPluginCookieBroker(
                provider: .abacus,
                domains: [domain],
                settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                batches: { _, _ in nil },
                jarImporter: { batch in
                    batches.append(batch)
                    return batch < 2 ? [.init(header: "", source: "Browser \(batch)", origin: "")] : nil
                })
            let first = try #require(try broker.nextSession(domain: domain))
            #expect(first.source == "Browser 0")
            #expect(batches.values == [0])
            broker.rejectCookie(domain: domain, id: first.id)
            #expect(try broker.nextSession(domain: domain)?.source == "Browser 1")
            #expect(batches.values == [0, 1])
            #expect(try broker.nextSession(domain: domain) == nil)
            #expect(try broker.nextSession(domain: domain) == nil)
            #expect(batches.values == [0, 1, 2])
        }
    }

    private final class BatchCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int] = []
        var values: [Int] {
            self.lock.withLock { self.storage }
        }

        func append(_ value: Int) { self.lock.withLock { self.storage.append(value) } }
    }

    private func broker(
        source: ProviderCookieSource = .auto,
        importer: @escaping ProviderPluginCookieBroker.Importer = { [("session=\($0)", "Fixture")] })
        -> ProviderPluginCookieBroker
    {
        ProviderPluginCookieBroker(
            provider: .manus,
            domains: self.domains,
            settings: .init(cookieSource: source, manualCookieHeader: "Cookie: session=manual"),
            importer: importer)
    }

    @Test
    func `nonpersistent jars neither read overwrite nor clear the provider cache`() throws {
        try self.isolated {
            CookieHeaderCache.store(provider: .longcat, cookieHeader: "session=old", sourceLabel: "Synthetic cached")
            let expected = try #require(CookieHeaderCache.load(provider: .longcat))
            let broker = ProviderPluginCookieBroker(
                provider: .longcat,
                domains: ["longcat.chat"],
                settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                batches: { _, _ in Issue.record("Legacy importer must not run"); return nil },
                jarImporter: { batch in batch == 0 ? [.init(
                    header: "",
                    source: "Synthetic import",
                    origin: "",
                    records: [])] : nil })
            #expect(try broker.nextSession(domain: "longcat.chat", cachedOnly: true) == nil)
            let session = try #require(try broker.nextSession(domain: "longcat.chat"))
            #expect(session.source == "Synthetic import")
            broker.rejectCookie(domain: "longcat.chat", id: session.id)
            #expect(try broker.nextSession(domain: "longcat.chat") == nil)
            let actual = try #require(CookieHeaderCache.load(provider: .longcat))
            #expect(actual.cookieHeader == expected.cookieHeader)
            #expect(actual.storedAt == expected.storedAt)
            #expect(actual.sourceLabel == expected.sourceLabel)
        }
    }

    private func isolated(_ body: () throws -> Void) rethrows {
        try KeychainCacheStore.withImplicitTestStoreForTesting {
            try KeychainCacheStore.withServiceOverrideForTesting("plugin-cookies-\(UUID().uuidString)") {
                let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: base) }
                try CookieHeaderCache.withLegacyBaseURLOverrideForTesting(base, operation: body)
            }
        }
    }
}

/// Single-batch fixture construction is test-only; production imports use the batched initializer.
extension ProviderPluginCookieBroker {
    typealias Importer = @Sendable (String) throws -> [(header: String, source: String)]

    convenience init(
        provider: UsageProvider,
        domains: Set<String>,
        settings: ProviderSettingsSnapshot.CookieProviderSettings,
        importer: @escaping Importer)
    {
        self.init(provider: provider, domains: domains, settings: settings, batches: { domain, batch in
            try batch == 0 ? importer(domain) : nil
        })
    }
}
