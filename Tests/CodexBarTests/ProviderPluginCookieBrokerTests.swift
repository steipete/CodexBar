import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginCookieBrokerTests {
    private let domains: Set<String> = ["cloud.example.test", "community.example.test"]

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
