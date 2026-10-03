import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct ProviderPluginCookieResultTests {
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

    @Test(arguments: BundledPluginTestSupport.engines, [UsageProvider.museai, .abacus])
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
