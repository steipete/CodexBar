import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginCookieBrokerTests {
    private let domains: Set<String> = ["cloud.example.test", "community.example.test"]

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
            for domain in self.domains {
                CookieHeaderCache.store(
                    provider: .manus,
                    scope: .providerVariant(domain),
                    cookieHeader: "session=cached",
                    sourceLabel: "Fixture")
                if source == .manual {
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

    private func broker(
        source: ProviderCookieSource = .auto,
        importer: @escaping ProviderPluginCookieBroker.Importer = { ("session=\($0)", "Fixture") })
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
